import Foundation
#if !COCOAPODS
import VIAudioDownloader
#endif

/// Audio source backed by a network URL. Reads from the download cache,
/// triggering on-demand range downloads for any missing bytes.
///
/// For the decoder, this looks like a regular random-access file. Reads may
/// block until the requested bytes have been downloaded.
///
/// - Note: 当前播放器使用 push 模式（`VIPushAudioSource`）处理网络流，
///   此类保留作为 pull 模式的备选方案，暂不在主播放路径中使用。
@available(*, deprecated, message: "使用 VIPushAudioSource 替代。此类保留作为 pull 模式网络源的备选实现。")
public final class VINetworkAudioSource: VIAudioSource {

    public let url: URL
    public let fileExtension: String

    private let downloader: VIChunkedDownloader
    private let cacheManager: VICacheManager
    private let unitKey: String
    private let lock = NSLock()
    private let dataCondition = NSCondition()
    private var isClosed = false

    /// Timeout for waiting on network data (seconds).
    public var readTimeout: TimeInterval = 30

    public init(url: URL, downloader: VIChunkedDownloader) {
        self.url = url
        self.fileExtension = url.pathExtension.lowercased()
        self.downloader = downloader
        self.cacheManager = downloader.cacheManager
        self.unitKey = downloader.configuration.cacheKey(for: url)
    }

    // MARK: - VIAudioSource

    public var contentLength: Int64? {
        cacheManager.existingUnit(for: url)?.totalLength
    }

    public var availableRanges: [Range<Int64>] {
        cacheManager.existingUnit(for: url)?.cachedRanges ?? []
    }

    public var isFullyAvailable: Bool {
        cacheManager.existingUnit(for: url)?.isComplete ?? false
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard !isClosed else { throw VIAudioSourceError.cancelled }

        let requestedEnd = offset + Int64(length)
        let range = offset..<requestedEnd
        let unit = cacheManager.unit(for: url)

        // Fast path: data is already cached
        if unit.isCached(range: range) {
            return try readFromCache(unit: unit, offset: offset, length: length)
        }

        // Trigger download for the missing range
        let task = downloader.downloadRange(url: url, range: range)

        // Wait for data to become available
        let deadline = Date().addingTimeInterval(readTimeout)
        dataCondition.lock()
        task.onDataAvailable = { [weak self] _ in
            self?.dataCondition.lock()
            self?.dataCondition.broadcast()
            self?.dataCondition.unlock()
        }
        task.onComplete = { [weak self] in
            self?.dataCondition.lock()
            self?.dataCondition.broadcast()
            self?.dataCondition.unlock()
        }
        task.onError = { [weak self] _ in
            self?.dataCondition.lock()
            self?.dataCondition.broadcast()
            self?.dataCondition.unlock()
        }

        while !isClosed && !unit.isCached(range: range) {
            if case .failed = task.state {
                dataCondition.unlock()
                throw VIAudioSourceError.readFailed
            }
            if case .cancelled = task.state {
                dataCondition.unlock()
                throw VIAudioSourceError.cancelled
            }
            let gotSignal = dataCondition.wait(until: deadline)
            if !gotSignal {
                dataCondition.unlock()
                throw VIAudioSourceError.downloadTimeout
            }
        }
        dataCondition.unlock()

        guard !isClosed else { throw VIAudioSourceError.cancelled }
        return try readFromCache(unit: unit, offset: offset, length: length)
    }

    public func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
        dataCondition.lock()
        dataCondition.broadcast()
        dataCondition.unlock()
    }

    deinit {
        close()
    }

    // MARK: - Private

    /// Read bytes from the cached segment files on disk.
    private func readFromCache(unit: VICacheUnit, offset: Int64, length: Int) throws -> Data {
        let range = offset..<(offset + Int64(length))
        let sources = VIDataSourceResolver.resolve(range: range, unit: unit)

        var result = Data()
        for source in sources {
            switch source {
            case .file(let segment, let readRange):
                let absPath = cacheManager.absoluteURL(forSegment: segment.relativePath, unitKey: unitKey)
                guard let handle = try? FileHandle(forReadingFrom: absPath) else {
                    throw VIAudioSourceError.readFailed
                }
                defer { try? handle.close() }
                let localOffset = readRange.lowerBound - segment.offset
                try handle.seek(toOffset: UInt64(localOffset))
                let data = handle.readData(ofLength: Int(readRange.upperBound - readRange.lowerBound))
                result.append(data)

            case .network:
                // Should not happen since we waited for the download to complete
                throw VIAudioSourceError.readFailed
            }
        }
        return result
    }
}
