import Foundation

/// Observable download task. Supports cancellation and progress tracking.
public final class VIDownloadTask: @unchecked Sendable {

    public enum State: Sendable {
        case idle
        case downloading
        case paused
        case completed
        case failed(Error)
        case cancelled
    }

    public let url: URL
    public let requestedRange: Range<Int64>?

    private let lock = NSLock()

    private var _state: State = .idle
    public private(set) var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _state
        }
        set {
            lock.lock()
            _state = newValue
            let callback = onStateChange
            lock.unlock()
            callback?(newValue)
        }
    }

    private var _downloadedBytes: Int64 = 0
    /// Bytes downloaded so far for this task.
    public private(set) var downloadedBytes: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _downloadedBytes
        }
        set {
            lock.lock()
            _downloadedBytes = newValue
            lock.unlock()
        }
    }

    private var _totalBytes: Int64 = 0
    /// Total expected bytes (from Content-Length or requested range size).
    public private(set) var totalBytes: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _totalBytes
        }
        set {
            lock.lock()
            _totalBytes = newValue
            lock.unlock()
        }
    }

    /// Progress callback (0.0 – 1.0).
    public var onProgress: ((_ progress: Double) -> Void)?

    /// State change callback.
    public var onStateChange: ((_ state: State) -> Void)?

    /// Called when the task finishes successfully.
    public var onComplete: (() -> Void)?

    /// Called when the task fails.
    public var onError: ((_ error: Error) -> Void)?

    /// Called when new data has been written to disk (for streaming readers).
    public var onDataAvailable: ((_ range: Range<Int64>) -> Void)?

    internal var sessionTask: URLSessionDataTask?
    internal let id = UUID()

    public init(url: URL, range: Range<Int64>? = nil) {
        self.url = url
        self.requestedRange = range
    }

    // MARK: - Control

    public func cancel() {
        sessionTask?.cancel()
        sessionTask = nil
        state = .cancelled
    }

    public func pause() {
        sessionTask?.cancel()
        sessionTask = nil
        state = .paused
    }

    // MARK: - Internal updates

    internal func markDownloading(totalBytes: Int64) {
        self.totalBytes = totalBytes
        self.state = .downloading
    }

    internal func appendBytes(_ count: Int64, writtenRange: Range<Int64>) {
        lock.lock()
        _downloadedBytes += count
        let total = _totalBytes
        let downloaded = _downloadedBytes
        lock.unlock()
        let progress = total > 0 ? Double(downloaded) / Double(total) : 0
        onProgress?(min(progress, 1.0))
        onDataAvailable?(writtenRange)
    }

    internal func markCompleted() {
        state = .completed
        onComplete?()
    }

    internal func markFailed(_ error: Error) {
        state = .failed(error)
        onError?(error)
    }
}

extension VIDownloadTask: Hashable {
    public static func == (lhs: VIDownloadTask, rhs: VIDownloadTask) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
