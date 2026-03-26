import Foundation
import Network
#if !COCOAPODS
import VIAudioDownloader
#endif

/// Push-based network data source for audio streaming.
///
/// Instead of the pull model (`read()` that blocks), this source actively pushes
/// data to consumers via callbacks. Data comes from cache when available,
/// or from the network via HTTP Range requests.
///
/// Resilience features:
/// - Automatic retry with exponential backoff on transient errors
/// - NWPathMonitor for detecting network recovery
/// - Seamless seek support (cancels current download, starts from new offset)
public final class VIPushAudioSource: @unchecked Sendable {

    // MARK: - Callbacks

    /// Raw data received, ready to be fed to the stream decoder.
    public var onDataReceived: ((_ data: Data) -> Void)?

    /// Total content length determined from server response.
    public var onContentLengthAvailable: ((_ length: Int64) -> Void)?

    /// All data has been received (download complete or file fully cached).
    public var onEndOfFile: (() -> Void)?

    /// Network became unavailable or recovered.
    public var onWaitingForNetworkChanged: ((_ waiting: Bool) -> Void)?

    /// Called when a fatal error occurs that cannot be retried.
    public var onError: ((_ error: Error) -> Void)?

    // MARK: - Public state

    public private(set) var contentLength: Int64?
    public private(set) var isWaitingForNetwork: Bool = false {
        didSet {
            if oldValue != isWaitingForNetwork {
                onWaitingForNetworkChanged?(isWaitingForNetwork)
            }
        }
    }
    public private(set) var currentOffset: Int64 = 0
    public private(set) var isClosed = false

    // MARK: - Configuration

    private let url: URL
    private let cacheManager: VICacheManager
    private let configuration: VIDownloaderConfiguration
    private var isPaused = false

    // MARK: - Network

    private var session: URLSession?
    private var activeDataTask: URLSessionDataTask?
    private var sessionDelegate: StreamSessionDelegate?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.viaudiokit.pushsource.network")
    private var networkAvailable = true
    private let workQueue = DispatchQueue(label: "com.viaudiokit.pushsource.work")

    // MARK: - Cache writing

    private var writeHandle: FileHandle?
    private var segmentRelativePath: String?
    private var segmentIndex: Int?
    private var segmentWrittenBytes: Int64 = 0

    // MARK: - Retry

    private var retryCount = 0
    private let maxRetries = 20
    private var retryWorkItem: DispatchWorkItem?

    private let lock = NSLock()

    // MARK: - Init

    public init(url: URL, cacheManager: VICacheManager, configuration: VIDownloaderConfiguration) {
        self.url = url
        self.cacheManager = cacheManager
        self.configuration = configuration

        let unit = cacheManager.unit(for: url)
        self.contentLength = unit.totalLength

        startPathMonitor()
    }

    deinit {
        close()
    }

    // MARK: - Control

    /// Start streaming from the given byte offset.
    public func start(from offset: Int64 = 0) {
        workQueue.async { [weak self] in
            self?.doStart(from: offset)
        }
    }

    /// Seek to a new byte offset. Cancels any in-progress download.
    public func seek(to offset: Int64) {
        workQueue.async { [weak self] in
            self?.cancelActiveDownload()
            self?.retryWorkItem?.cancel()
            self?.retryCount = 0
            self?.doStart(from: offset)
        }
    }

    /// Suspend data pushing (pause).
    public func suspend() {
        lock.lock()
        isPaused = true
        activeDataTask?.suspend()
        lock.unlock()
    }

    /// Resume data pushing.
    public func resume() {
        lock.lock()
        isPaused = false
        activeDataTask?.resume()
        lock.unlock()
    }

    /// Close and release all resources.
    public func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        lock.unlock()

        cancelActiveDownload()
        retryWorkItem?.cancel()
        pathMonitor.cancel()
        closeWriteHandle()
    }

    // MARK: - Internal streaming

    private func doStart(from offset: Int64) {
        guard !isClosed else { return }
        currentOffset = offset

        let unit = cacheManager.unit(for: url)

        debugPrint("[VIPushAudioSource] doStart: offset=\(offset) unit.totalLength=\(String(describing: unit.totalLength)) self.contentLength=\(String(describing: contentLength)) cachedRanges=\(unit.cachedRanges)")

        if let total = unit.totalLength ?? contentLength {
            if contentLength == nil {
                contentLength = total
                debugPrint("[VIPushAudioSource] doStart: notifying contentLength=\(total)")
                onContentLengthAvailable?(total)
            }
            if offset >= total {
                onEndOfFile?()
                return
            }
            pushCachedDataThenDownload(unit: unit, from: offset, total: total)
        } else {
            debugPrint("[VIPushAudioSource] doStart: no total length known, starting network request")
            startNetworkRequest(from: offset)
        }
    }

    /// Push any cached data starting at `offset`, then start downloading from the uncached position.
    private func pushCachedDataThenDownload(unit: VICacheUnit, from offset: Int64, total: Int64) {
        let cachedRanges = unit.cachedRanges
        var readCursor = offset

        for cr in cachedRanges {
            guard readCursor < total, !isClosed else { break }
            guard cr.upperBound > readCursor else { continue }
            guard cr.lowerBound <= readCursor else { break }

            let readEnd = min(cr.upperBound, total)
            readCachedData(unit: unit, from: readCursor, to: readEnd)
            readCursor = readEnd
        }

        currentOffset = readCursor
        if readCursor >= total {
            onEndOfFile?()
            return
        }

        startNetworkRequest(from: readCursor)
    }

    /// Read cached data from disk and push it.
    private func readCachedData(unit: VICacheUnit, from start: Int64, to end: Int64) {
        let segments = unit.segments
        let chunkSize = 32768 // 32KB read chunks
        var cursor = start

        while cursor < end, !isClosed {
            guard let seg = segments.first(where: { $0.contains(cursor) }) else { break }
            let segFile = cacheManager.absoluteURL(forSegment: seg.relativePath, unitKey: unit.key)
            guard let handle = try? FileHandle(forReadingFrom: segFile) else { break }
            defer { try? handle.close() }

            let fileOffset = cursor - seg.offset
            try? handle.seek(toOffset: UInt64(fileOffset))

            let bytesToRead = min(end - cursor, seg.end - cursor)
            var remaining = bytesToRead

            while remaining > 0, !isClosed {
                let readLen = min(Int(remaining), chunkSize)
                let data = handle.readData(ofLength: readLen)
                guard !data.isEmpty else { break }
                onDataReceived?(data)
                remaining -= Int64(data.count)
                cursor += Int64(data.count)
                currentOffset = cursor
            }
        }
    }

    // MARK: - Network request

    private func startNetworkRequest(from offset: Int64) {
        guard !isClosed else { return }

        lock.lock()
        let paused = isPaused
        lock.unlock()

        if !networkAvailable {
            isWaitingForNetwork = true
            return
        }

        isWaitingForNetwork = false

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = configuration.requestTimeoutInterval

        if let total = contentLength {
            request.setValue("bytes=\(offset)-\(total - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let delegate = StreamSessionDelegate(source: self, startOffset: offset)
        self.sessionDelegate = delegate

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let newSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = newSession

        let task = newSession.dataTask(with: request)
        task.priority = URLSessionTask.highPriority
        self.activeDataTask = task

        if paused {
            task.suspend()
        }

        prepareCacheSegment(at: offset)
        task.resume()
    }

    // MARK: - Cache segment preparation

    private func prepareCacheSegment(at offset: Int64) {
        closeWriteHandle()
        let unit = cacheManager.unit(for: url)
        let (relativePath, absoluteURL) = cacheManager.segmentFilePath(unitKey: unit.key, offset: offset)
        self.segmentRelativePath = relativePath

        let segment = VICacheSegment(relativePath: relativePath, offset: offset, length: 0)
        unit.insertSegment(segment)
        self.segmentIndex = unit.segmentIndex(for: relativePath)
        self.segmentWrittenBytes = 0

        self.writeHandle = try? FileHandle(forWritingTo: absoluteURL)
    }

    private func closeWriteHandle() {
        try? writeHandle?.synchronize()
        try? writeHandle?.close()
        writeHandle = nil
    }

    // MARK: - Delegate handling (called from URLSession delegate)

    fileprivate func handleResponse(_ response: HTTPURLResponse) {
        debugPrint("[VIPushAudioSource] handleResponse: status=\(response.statusCode) contentLength=\(String(describing: contentLength)) headers=\(response.allHeaderFields["Content-Range"] ?? "nil")")
        if contentLength == nil {
            var totalLength: Int64?
            if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
               let slashIndex = contentRange.lastIndex(of: "/") {
                let totalStr = contentRange[contentRange.index(after: slashIndex)...]
                totalLength = Int64(totalStr)
            }
            if totalLength == nil {
                let cl = response.expectedContentLength
                if cl > 0 { totalLength = cl + currentOffset }
            }
            debugPrint("[VIPushAudioSource] handleResponse: resolved totalLength=\(String(describing: totalLength))")
            if let total = totalLength {
                contentLength = total
                let unit = cacheManager.unit(for: url)
                unit.totalLength = total
                if let h = response.allHeaderFields as? [String: String] {
                    unit.responseHeaders = h
                }
                cacheManager.scheduleSave()
                onContentLengthAvailable?(total)
            }
        }
    }

    private var handleDataCallCount = 0
    fileprivate func handleData(_ data: Data) {
        guard !isClosed else { return }

        // Write to cache
        if let handle = writeHandle {
            try? handle.write(contentsOf: data)
            segmentWrittenBytes += Int64(data.count)
            if let idx = segmentIndex {
                let unit = cacheManager.unit(for: url)
                unit.updateSegmentLength(at: idx, length: segmentWrittenBytes)
            }
        }

        handleDataCallCount += 1
        if handleDataCallCount <= 3 || handleDataCallCount % 100 == 0 {
            debugPrint("[VIPushAudioSource] handleData #\(handleDataCallCount): \(data.count) bytes, currentOffset=\(currentOffset + Int64(data.count))")
        }

        currentOffset += Int64(data.count)
        onDataReceived?(data)
    }

    fileprivate func handleComplete(error: Error?) {
        closeWriteHandle()
        cacheManager.scheduleSave()

        session?.invalidateAndCancel()
        session = nil
        activeDataTask = nil

        guard !isClosed else { return }

        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }

            debugPrint("[VIPushAudioSource] download error: \(error.localizedDescription)")

            if nsError.code == NSURLErrorNotConnectedToInternet ||
               nsError.code == NSURLErrorNetworkConnectionLost ||
               nsError.code == NSURLErrorDataNotAllowed {
                isWaitingForNetwork = true
            } else {
                scheduleRetry()
            }
            return
        }

        retryCount = 0

        // Check if we're done
        if let total = contentLength, currentOffset >= total {
            let unit = cacheManager.unit(for: url)
            unit.mergeIfNeeded(in: cacheManager.directoryForUnit(unit.key))
            cacheManager.scheduleSave()
            onEndOfFile?()
        } else if contentLength == nil {
            onEndOfFile?()
        }
    }

    // MARK: - Retry logic

    private func scheduleRetry() {
        guard retryCount < maxRetries, !isClosed else {
            onError?(VIAudioSourceError.readFailed)
            return
        }
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), 30.0)
        debugPrint("[VIPushAudioSource] retry #\(retryCount) in \(delay)s from offset \(currentOffset)")

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.startNetworkRequest(from: self.currentOffset)
        }
        retryWorkItem = item
        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - NWPathMonitor

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = (path.status == .satisfied)
            let wasUnavailable = !self.networkAvailable

            self.networkAvailable = available

            if available && (wasUnavailable || self.isWaitingForNetwork) {
                debugPrint("[VIPushAudioSource] network recovered, resuming from offset \(self.currentOffset)")
                self.workQueue.async {
                    guard !self.isClosed, self.isWaitingForNetwork else { return }
                    self.isWaitingForNetwork = false
                    self.retryCount = 0
                    self.startNetworkRequest(from: self.currentOffset)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    // MARK: - Helpers

    private func cancelActiveDownload() {
        activeDataTask?.cancel()
        activeDataTask = nil
        session?.invalidateAndCancel()
        session = nil
        closeWriteHandle()
    }
}

// MARK: - URLSession delegate

private final class StreamSessionDelegate: NSObject, URLSessionDataDelegate {
    private weak var source: VIPushAudioSource?
    private let startOffset: Int64
    private var responseReceived = false

    init(source: VIPushAudioSource, startOffset: Int64) {
        self.source = source
        self.startOffset = startOffset
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 206 else {
            completionHandler(.cancel)
            return
        }
        responseReceived = true
        source?.handleResponse(http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        source?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        source?.handleComplete(error: error)
    }
}
