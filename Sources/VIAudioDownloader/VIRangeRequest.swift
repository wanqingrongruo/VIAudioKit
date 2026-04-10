import Foundation

/// Manages a single HTTP Range request, writing received data into a cache segment file.
/// Analogous to KTVHTTPCache's `KTVHCDataNetworkSource` + `KTVHCDownload`.
final class VIRangeRequest: NSObject, @unchecked Sendable {

    let url: URL
    let range: Range<Int64>
    let cacheManager: VICacheManager
    let unitKey: String
    let configuration: VIDownloaderConfiguration

    private var ownedSession: URLSession?
    private(set) var dataTask: URLSessionDataTask?
    private var writeHandle: FileHandle?
    private var segmentRelativePath: String?
    private var segmentIndex: Int?
    private var writtenBytes: Int64 = 0
    private let lock = NSLock()

    var onResponse: ((_ contentLength: Int64, _ totalLength: Int64?, _ headers: [String: String]) -> Void)?
    var onData: ((_ bytesWritten: Int64, _ writtenRange: Range<Int64>) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((_ error: Error) -> Void)?

    init(url: URL, range: Range<Int64>, unitKey: String,
         cacheManager: VICacheManager, configuration: VIDownloaderConfiguration) {
        self.url = url
        self.range = range
        self.unitKey = unitKey
        self.cacheManager = cacheManager
        self.configuration = configuration
        super.init()
    }

    // MARK: - Start / Cancel

    func start() {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = configuration.requestTimeoutInterval
        let rangeEnd = range.upperBound - 1
        request.setValue("bytes=\(range.lowerBound)-\(rangeEnd)", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let owned = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        ownedSession = owned
        
        dataTask = owned.dataTask(with: request)
        dataTask?.priority = URLSessionTask.highPriority
        dataTask?.resume()
    }

    func cancel() {
        dataTask?.cancel()
        dataTask = nil
        closeHandles()
        invalidateSession()
    }

    // MARK: - Helpers

    private func closeHandles() {
        lock.lock()
        try? writeHandle?.synchronize()
        try? writeHandle?.close()
        writeHandle = nil
        lock.unlock()
    }

    private func invalidateSession() {
        ownedSession?.invalidateAndCancel()
        ownedSession = nil
    }
}

// MARK: - URLSessionDataDelegate

extension VIRangeRequest: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            onError?(VIDownloadError.invalidResponse)
            completionHandler(.cancel)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            onError?(VIDownloadError.httpError(statusCode: httpResponse.statusCode))
            completionHandler(.cancel)
            return
        }

        let contentLength = httpResponse.expectedContentLength
        let headers = httpResponse.allHeaderFields as? [String: String] ?? [:]

        // Parse total length from Content-Range: bytes 0-999/5000
        var totalLength: Int64?
        if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRange.lastIndex(of: "/") {
            let totalStr = contentRange[contentRange.index(after: slashIndex)...]
            totalLength = Int64(totalStr)
        }

        // Create segment file
        let (relativePath, absoluteURL) = cacheManager.segmentFilePath(unitKey: unitKey, offset: range.lowerBound)
        self.segmentRelativePath = relativePath

        let segment = VICacheSegment(relativePath: relativePath, offset: range.lowerBound, length: 0)
        let unit = cacheManager.unit(for: url)
        unit.insertSegment(segment)
        self.segmentIndex = unit.segmentIndex(for: relativePath)

        if let total = totalLength {
            unit.totalLength = total
            if let h = httpResponse.allHeaderFields as? [String: String] {
                unit.responseHeaders = h
            }
        }

        lock.lock()
        self.writeHandle = try? FileHandle(forWritingTo: absoluteURL)
        lock.unlock()

        onResponse?(contentLength, totalLength, headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let handle = writeHandle else { lock.unlock(); return }
        do {
            try handle.write(contentsOf: data)
            writtenBytes += Int64(data.count)

            if let idx = segmentIndex {
                let unit = cacheManager.unit(for: url)
                unit.updateSegmentLength(at: idx, length: writtenBytes)
            }
        } catch {
            lock.unlock()
            onError?(error)
            return
        }
        let rangeStart = range.lowerBound + writtenBytes - Int64(data.count)
        let rangeEnd = range.lowerBound + writtenBytes
        lock.unlock()

        onData?(Int64(data.count), rangeStart..<rangeEnd)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closeHandles()
        if let error = error {
            // 取消时也需要清理 session，不能跳过
            if (error as NSError).code == NSURLErrorCancelled {
                invalidateSession()
                return
            }
            onError?(error)
        } else {
            cacheManager.scheduleSave()
            onComplete?()
        }
        invalidateSession()
    }
}

// MARK: - Errors

public enum VIDownloadError: Error, Sendable {
    case invalidResponse
    case httpError(statusCode: Int)
    case insufficientDiskSpace
    case fileWriteError
}
