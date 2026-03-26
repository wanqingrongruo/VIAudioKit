import Foundation

/// Public entry point for downloading and caching audio resources.
/// Completely independent of the player — can be used for any file download.
public final class VIChunkedDownloader: @unchecked Sendable {

    public let cacheManager: VICacheManager
    public let configuration: VIDownloaderConfiguration

    private var activeRequests: [UUID: VIRangeRequest] = [:]
    private let lock = NSLock()

    // MARK: - Init

    public init(configuration: VIDownloaderConfiguration = VIDownloaderConfiguration()) {
        self.configuration = configuration
        self.cacheManager = VICacheManager(configuration: configuration)
    }

    public init(cacheManager: VICacheManager) {
        self.cacheManager = cacheManager
        self.configuration = cacheManager.configuration
    }

    // MARK: - Download entire file

    /// Download the entire resource, skipping already-cached ranges.
    @discardableResult
    public func download(url: URL) -> VIDownloadTask {
        let task = VIDownloadTask(url: url)
        let unit = cacheManager.unit(for: url)
        unit.retainWorking()

        // First we need to know the total length. Fire a HEAD or a small range request.
        resolveContentLength(url: url, unit: unit) { [weak self] totalLength in
            guard let self, let totalLength else {
                task.markFailed(VIDownloadError.invalidResponse)
                unit.releaseWorking()
                return
            }
            unit.totalLength = totalLength
            task.markDownloading(totalBytes: totalLength)

            let fullRange: Range<Int64> = 0..<totalLength
            let sources = VIDataSourceResolver.resolve(range: fullRange, unit: unit)

            let networkRanges: [Range<Int64>] = sources.compactMap {
                if case .network(let range) = $0 { return range }
                return nil
            }

            guard !networkRanges.isEmpty else {
                // Fully cached already
                unit.releaseWorking()
                unit.mergeIfNeeded(in: self.cacheManager.directoryForUnit(unit.key))
                self.cacheManager.scheduleSave()
                task.markCompleted()
                return
            }

            self.downloadRangesSequentially(
                url: url, unit: unit, ranges: networkRanges, task: task
            ) {
                unit.releaseWorking()
                unit.mergeIfNeeded(in: self.cacheManager.directoryForUnit(unit.key))
                self.cacheManager.scheduleSave()
                task.markCompleted()
            } onError: { error in
                unit.releaseWorking()
                self.cacheManager.scheduleSave()
                task.markFailed(error)
            }
        }
        return task
    }

    // MARK: - Download specific range (used by player seek)

    /// Download a specific byte range. Returns immediately if already cached.
    @discardableResult
    public func downloadRange(url: URL, range: Range<Int64>) -> VIDownloadTask {
        let task = VIDownloadTask(url: url, range: range)
        let unit = cacheManager.unit(for: url)

        if unit.isCached(range: range) {
            task.markDownloading(totalBytes: Int64(range.count))
            task.markCompleted()
            return task
        }

        unit.retainWorking()
        task.markDownloading(totalBytes: Int64(range.count))

        let sources = VIDataSourceResolver.resolve(range: range, unit: unit)
        let networkRanges: [Range<Int64>] = sources.compactMap {
            if case .network(let r) = $0 { return r }
            return nil
        }

        guard !networkRanges.isEmpty else {
            unit.releaseWorking()
            task.markCompleted()
            return task
        }

        downloadRangesSequentially(url: url, unit: unit, ranges: networkRanges, task: task) {
            unit.releaseWorking()
            self.cacheManager.scheduleSave()
            task.markCompleted()
        } onError: { error in
            unit.releaseWorking()
            self.cacheManager.scheduleSave()
            task.markFailed(error)
        }

        return task
    }

    // MARK: - Preload

    /// Preload the first N bytes of a resource (e.g. header + first audio frames).
    @discardableResult
    public func preload(url: URL, length: Int64) -> VIDownloadTask {
        return downloadRange(url: url, range: 0..<length)
    }

    // MARK: - Cache queries (forwarded)

    public func cacheStatus(for url: URL) -> VICacheStatus {
        cacheManager.cacheStatus(for: url)
    }

    public func completeCacheURL(for url: URL) -> URL? {
        cacheManager.completeCacheURL(for: url)
    }

    public func removeCache(for url: URL) {
        cacheManager.removeCache(for: url)
    }

    public func removeAllCache() {
        cacheManager.removeAllCache()
    }

    /// Cancel all active network requests.
    public func cancelAll() {
        lock.lock()
        let requests = Array(activeRequests.values)
        activeRequests.removeAll()
        lock.unlock()
        requests.forEach { $0.cancel() }
    }

    // MARK: - Internal

    private func resolveContentLength(url: URL, unit: VICacheUnit,
                                      completion: @escaping (Int64?) -> Void) {
        if let total = unit.totalLength {
            completion(total)
            return
        }
        // Issue a small Range request to get Content-Range header
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = configuration.requestTimeoutInterval
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse else {
                completion(nil)
                return
            }
            // Try Content-Range: bytes 0-0/12345
            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
               let slashIndex = contentRange.lastIndex(of: "/") {
                let totalStr = contentRange[contentRange.index(after: slashIndex)...]
                completion(Int64(totalStr))
                return
            }
            // Fallback: Content-Length (server doesn't support Range)
            let cl = httpResponse.expectedContentLength
            completion(cl > 0 ? cl : nil)
        }
        task.resume()
    }

    private func downloadRangesSequentially(
        url: URL, unit: VICacheUnit, ranges: [Range<Int64>],
        task: VIDownloadTask,
        onAllComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        var remaining = ranges
        guard !remaining.isEmpty else {
            onAllComplete()
            return
        }

        let range = remaining.removeFirst()
        let rangeReq = VIRangeRequest(
            url: url, range: range, unitKey: unit.key,
            cacheManager: cacheManager, configuration: configuration
        )

        let reqID = UUID()
        lock.lock()
        activeRequests[reqID] = rangeReq
        lock.unlock()

        rangeReq.onData = { [weak task] bytesWritten, writtenRange in
            task?.appendBytes(bytesWritten, writtenRange: writtenRange)
        }

        rangeReq.onComplete = { [weak self] in
            self?.lock.lock()
            self?.activeRequests.removeValue(forKey: reqID)
            self?.lock.unlock()
            self?.downloadRangesSequentially(
                url: url, unit: unit, ranges: remaining,
                task: task, onAllComplete: onAllComplete, onError: onError
            )
        }

        rangeReq.onError = { [weak self] error in
            self?.lock.lock()
            self?.activeRequests.removeValue(forKey: reqID)
            self?.lock.unlock()
            onError(error)
        }

        rangeReq.start()
        task.sessionTask = rangeReq.dataTask
    }

    private var dataTask: URLSessionDataTask? { nil }
}
