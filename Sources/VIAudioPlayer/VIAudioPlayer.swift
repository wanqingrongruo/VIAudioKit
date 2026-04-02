import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
#endif

// MARK: - Delegate

/// Delegate for player state, time progress, buffer state and errors.
public protocol VIAudioPlayerDelegate: AnyObject {
    func player(_ player: VIAudioPlayer, didChangeState state: VIPlayerState)
    func player(_ player: VIAudioPlayer, didUpdateTime currentTime: TimeInterval, duration: TimeInterval)
    func player(_ player: VIAudioPlayer, didUpdateBuffer state: VIBufferState)
    func player(_ player: VIAudioPlayer, didReceiveError error: VIPlayerError)
}

public extension VIAudioPlayerDelegate {
    func player(_ player: VIAudioPlayer, didUpdateBuffer state: VIBufferState) {}
}

// MARK: - Buffering reason (internal)

/// Tracks why we entered the buffering state — determines how much data
/// we need before resuming playback.
private enum BufferingReason {
    case initialLoad
    case afterSeek
    case underrun
}

// MARK: - Player

/// Main entry point. Coordinates decoding, buffering and rendering.
///
/// **Dual-path architecture:**
/// - **Local files**: Pull-based decode loop using `VINativeDecoder` + `ExtAudioFile`
/// - **Network files**: Push-based pipeline using `VIPushAudioSource` → `VIStreamDecoder`
///
/// The push model for network sources eliminates blocking reads and provides
/// natural resilience to network interruptions.
public final class VIAudioPlayer: @unchecked Sendable {

    // MARK: - Public properties

    public weak var delegate: VIAudioPlayerDelegate?
    public let configuration: VIPlayerConfiguration

    public private(set) var state: VIPlayerState = .idle {
        didSet {
            guard state != oldValue else { return }
            let newState = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didChangeState: newState)
            }
        }
    }

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    public var isPlaying: Bool { state == .playing }

    /// Playback rate (0.5 – 2.0 typical).
    public var rate: Float {
        get { renderer.rate }
        set {
            desiredRate = newValue
            renderer.rate = newValue
        }
    }

    // MARK: - Internal components

    private let downloader: VIChunkedDownloader
    private let renderer = VIAudioRenderer()
    private let bufferQueue: VIAudioBufferQueue

    // Pull-mode (local files)
    private var decoder: VIAudioDecoding?
    private var source: VIAudioSource?

    // Push-mode (network files)
    private var streamDecoder: VIStreamDecoding?
    private var pushSource: VIPushAudioSource?
    private var isNetworkMode = false
    private var networkFileExt: String = ""

    private var currentURL: URL?
    private var desiredRate: Float = 1.0
    private var isSeeking = false
    private var shouldStopDecoding = false
    private var seekGeneration: Int = 0
    private var loadGeneration: Int = 0

    /// The audio-time offset at which the current play/seek segment started.
    private var playbackBaseTime: TimeInterval = 0

    /// Whether the user requested play (even while in buffering state).
    private var playWhenReady = false

    /// Tracks why we're in buffering state (to pick the right threshold).
    private var bufferingReason: BufferingReason?

    /// Set to true when the stream decoder signaled end-of-stream (all data pushed).
    private var streamEndReached = false

    /// Total decoded audio duration accumulated since the last buffering start (network mode).
    /// Incremented by every `onBufferReady` callback; reset on load/seek/underrun.
    private var networkBufferedDuration: TimeInterval = 0

    private var timeUpdateTimer: DispatchSourceTimer?
    private let decodeQueue = DispatchQueue(label: "com.viaudiokit.decode", qos: .userInitiated)
    private let pushQueue = DispatchQueue(label: "com.viaudiokit.push", qos: .userInitiated)
    private let renderControlQueue = DispatchQueue(label: "com.viaudiokit.render.control", qos: .userInitiated)
    /// Serial queue protecting all mutable state that is read/written across threads
    /// (generation counters, isSeeking, networkBufferedDuration, etc.).
    private let stateQueue = DispatchQueue(label: "com.viaudiokit.player.state")

    /// Registry of pull-mode decoder types. Add custom decoders here.
    public var decoderTypes: [VIAudioDecoding.Type] = [VINativeDecoder.self]

    /// Registry of push-mode (stream) decoder types.
    /// The player iterates through these and picks the first one supporting the file extension.
    public var streamDecoderTypes: [VIStreamDecoding.Type] = [VIStreamDecoder.self]

    // MARK: - Init

    public init(configuration: VIPlayerConfiguration = VIPlayerConfiguration()) {
        self.configuration = configuration
        self.downloader = VIChunkedDownloader(configuration: configuration.downloaderConfiguration)
        self.bufferQueue = VIAudioBufferQueue(capacity: configuration.decodeBufferCount)
        setupRendererCallbacks()
    }

    public init(configuration: VIPlayerConfiguration = VIPlayerConfiguration(),
                downloader: VIChunkedDownloader) {
        self.configuration = configuration
        self.downloader = downloader
        self.bufferQueue = VIAudioBufferQueue(capacity: configuration.decodeBufferCount)
        setupRendererCallbacks()
    }

    private func setupRendererCallbacks() {
        renderer.onNeedsData = { [weak self] in
            self?.feedRenderer()
        }
        renderer.onInterruption = { [weak self] began in
            guard let self else { return }
            if began {
                if self.state == .playing {
                    self.playWhenReady = true
                    self.state = .paused
                    self.stopTimeUpdates()
                }
            }
        }
    }

    deinit {
        stop()
    }

    // MARK: - Load

    /// Load an audio resource. Accepts both local file URLs and remote HTTP URLs.
    public func load(url: URL) {
        stop()
        currentURL = url
        playbackBaseTime = 0
        playWhenReady = false
        streamEndReached = false
        networkBufferedDuration = 0

        let thisLoad: Int = stateQueue.sync {
            loadGeneration += 1
            return loadGeneration
        }

        state = .preparing

        VILogger.debug("[VIAudioPlayer] load: \(url.lastPathComponent) isFile=\(url.isFileURL)")

        if url.isFileURL {
            isNetworkMode = false
            loadLocalFile(url: url, extensionHint: nil, thisLoad: thisLoad)
        } else {
            if let cachedURL = downloader.completeCacheURL(for: url) {
                VILogger.debug("[VIAudioPlayer] load: fully cached, using local file path")
                isNetworkMode = false
                let originalExt = url.pathExtension.lowercased()
                loadLocalFile(url: cachedURL, extensionHint: originalExt, thisLoad: thisLoad)
            } else {
                isNetworkMode = true
                loadNetworkFile(url: url, thisLoad: thisLoad)
            }
        }
    }

    // MARK: - Load: Local (Pull)

    /// - Parameter extensionHint: Override file extension (used when loading from cache
    ///   where the on-disk filename is a hash, not the original name).
    private func loadLocalFile(url: URL, extensionHint: String?, thisLoad: Int) {
        decodeQueue.async { [weak self] in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else {
                VILogger.debug("[VIAudioPlayer] load: stale (generation \(thisLoad)), skipping")
                return
            }

            do {
                let source = try VILocalFileSource(fileURL: url)
                self.source = source

                let ext = (extensionHint?.isEmpty == false) ? extensionHint! : source.fileExtension
                VILogger.debug("[VIAudioPlayer] load: ext=\(ext) size=\(source.contentLength ?? -1)")

                guard let decoderType = self.decoderTypes.first(where: {
                    $0.supportedExtensions.contains(ext)
                }) else {
                    throw VIPlayerError.decoderCreationFailed(
                        VIDecoderError.unsupportedFormat(ext)
                    )
                }

                let decoder = try decoderType.init(source: source)

                let staleAfterDecode: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
                if staleAfterDecode {
                    decoder.close()
                    VILogger.debug("[VIAudioPlayer] load: stale after decode init, skipping")
                    return
                }

                self.decoder = decoder
                self.duration = decoder.duration

                VILogger.debug("[VIAudioPlayer] load: decoder ready, duration=\(String(format: "%.2f", decoder.duration))s")
                try self.renderer.prepare(format: decoder.outputFormat)
                VILogger.debug("[VIAudioPlayer] load: renderer prepared, setting state=ready")
                self.state = .ready
                if self.playWhenReady {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let stillCurrent = self.stateQueue.sync { thisLoad == self.loadGeneration }
                        guard stillCurrent else { return }
                        self.play()
                    }
                }
            } catch {
                let stillCurrent: Bool = self.stateQueue.sync { thisLoad == self.loadGeneration }
                guard stillCurrent else { return }

                VILogger.debug("[VIAudioPlayer] load failed: \(error)")
                let playerError = self.wrapError(error)
                self.state = .failed(playerError)
                DispatchQueue.main.async {
                    self.delegate?.player(self, didReceiveError: playerError)
                }
            }
        }
    }

    // MARK: - Load: Network (Push)

    private func loadNetworkFile(url: URL, thisLoad: Int) {
        let ext = url.pathExtension.lowercased()
        self.networkFileExt = ext

        let ps = VIPushAudioSource(
            url: url,
            cacheManager: downloader.cacheManager,
            configuration: configuration.downloaderConfiguration
        )
        // Push-mode (network files)
        let sdType = streamDecoderTypes.first(where: {
            $0.supportedExtensions.contains(ext)
        }) ?? VIStreamDecoder.self
        
        let sd = sdType.init()
        sd.framesPerBuffer = configuration.framesPerBuffer

        self.pushSource = ps
        self.streamDecoder = sd

        let hint = VIStreamDecoder.fileTypeHint(for: ext)
        do {
            try sd.open(fileTypeHint: hint)
        } catch {
            VILogger.debug("[VIAudioPlayer] load: stream decoder open failed: \(error)")
            let playerError = VIPlayerError.decoderCreationFailed(error)
            state = .failed(playerError)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didReceiveError: playerError)
            }
            return
        }

        state = .buffering
        bufferingReason = .initialLoad

        // Wire push source → stream decoder → buffer queue → renderer
        ps.onContentLengthAvailable = { [weak self, weak sd] length in
            guard let self, let sd else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            sd.contentLength = length
            sd.updateDuration()
            if sd.duration > 0 {
                self.duration = sd.duration
                VILogger.debug("[VIAudioPlayer] duration updated from content length: \(String(format: "%.2f", sd.duration))s")
            }
        }

        var dataChunkCount = 0
        ps.onDataReceived = { [weak self, weak sd] data in
            guard let self, let sd else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            dataChunkCount += 1
            if dataChunkCount <= 5 || dataChunkCount % 50 == 0 {
                VILogger.debug("[VIAudioPlayer] onDataReceived #\(dataChunkCount): \(data.count) bytes, total fed to decoder=\(sd.totalBytesReceived + Int64(data.count))")
            }
            sd.feed(data)
        }

        sd.onOutputFormatReady = { [weak self] format, dur in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            if dur > 0 {
                self.duration = dur
            }
            do {
                try self.renderer.prepare(format: format)
            } catch {
                VILogger.debug("[VIAudioPlayer] renderer prepare failed: \(error)")
            }
            VILogger.debug("[VIAudioPlayer] load(network): format ready, duration=\(String(format: "%.2f", self.duration))s")
        }

        var bufferReadyCount = 0
        sd.onBufferReady = { [weak self] buffer in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            let rate = buffer.format.sampleRate
            let bufDur = rate > 0 ? Double(buffer.frameLength) / rate : 0
            let accumulated: TimeInterval = self.stateQueue.sync {
                self.networkBufferedDuration += bufDur
                return self.networkBufferedDuration
            }

            bufferReadyCount += 1
            if bufferReadyCount <= 5 || bufferReadyCount % 50 == 0 {
                VILogger.debug("[VIAudioPlayer] onBufferReady #\(bufferReadyCount): frames=\(buffer.frameLength) state=\(self.state) accumulated=\(String(format: "%.2f", accumulated))s")
            }

            if self.state == .playing {
                self.renderer.scheduleBuffer(buffer)
            } else {
                if !self.bufferQueue.tryEnqueue(buffer) {
                    self.renderer.scheduleBuffer(buffer)
                }
            }
        }

        sd.onEndOfStream = { [weak self] in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            self.streamEndReached = true
            self.feedRenderer()
            self.checkStreamFinished()
        }

        sd.onError = { [weak self] error in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] stream decoder error: \(error)")
        }

        ps.onWaitingForNetworkChanged = { [weak self] waiting in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            if waiting {
                VILogger.debug("[VIAudioPlayer] waiting for network…")
            } else {
                VILogger.debug("[VIAudioPlayer] network recovered")
            }
        }

        ps.onEndOfFile = { [weak self] in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] push source: end of file")
            self.streamEndReached = true
            self.streamDecoder?.flush()
            self.feedRenderer()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkBufferingToPlaying()
                self.checkStreamFinished()
                self.notifyBufferState()
            }
        }

        ps.onError = { [weak self] error in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] push source fatal error: \(error)")
            let playerError = VIPlayerError.networkError(error)
            DispatchQueue.main.async {
                self.state = .failed(playerError)
                self.delegate?.player(self, didReceiveError: playerError)
            }
        }

        // Start streaming and periodic buffer checks
        ps.start()
        startTimeUpdates()
    }

    // MARK: - Play

    public func play() {
        playWhenReady = true
        
        if isNetworkMode {
            // Accept play() in any state for network mode (including preparing/buffering)
            guard state == .ready || state == .paused || state == .buffering || state == .preparing else { return }
            pushSource?.resume()

            let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
            let required = requiredBufferDuration()
            VILogger.debug("[VIAudioPlayer] play(): network mode, accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s streamEnd=\(streamEndReached)")

            if accumulated >= required || (streamEndReached && accumulated > 0) {
                state = .playing
                startNetworkRendererAsync()
                bufferingReason = nil
                VILogger.debug("[VIAudioPlayer] play(): immediate transition to playing")
            } else {
                if state != .buffering {
                    bufferingReason = .initialLoad
                    state = .buffering
                }
            }
            startTimeUpdates()
            return
        }

        guard state == .ready || state == .paused || state == .preparing else { return }
        if state == .preparing { return }

        state = .playing
        renderer.rate = desiredRate
        do {
            try renderer.play()
        } catch {
            let playerError = VIPlayerError.renderingFailed(error)
            state = .failed(playerError)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didReceiveError: playerError)
            }
            return
        }
        startDecoding()
        startTimeUpdates()
    }

    // MARK: - Pause

    public func pause() {
        guard state == .playing || state == .buffering else { return }
        playWhenReady = false
        renderer.pause()
        if isNetworkMode {
            pushSource?.suspend()
        }
        state = .paused
        stopTimeUpdates()
    }

    // MARK: - Stop

    public func stop() {
        // Pull-mode cleanup
        shouldStopDecoding = true
        bufferQueue.flush()
        stopTimeUpdates()
        renderer.stop()

        decoder?.close()
        decoder = nil
        source?.close()
        source = nil

        // Push-mode cleanup
        pushSource?.close()
        pushSource = nil
        streamDecoder?.close()
        streamDecoder = nil

        currentURL = nil
        currentTime = 0
        duration = 0
        playbackBaseTime = 0
        playWhenReady = false
        isNetworkMode = false
        streamEndReached = false
        bufferingReason = nil
        networkBufferedDuration = 0

        state = .idle
    }

    // MARK: - Seek

    /// Seek to a specific time in seconds.
    public func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        let targetTime = max(0, min(time, duration))

        if isNetworkMode {
            seekNetwork(to: targetTime, completion: completion)
        } else {
            seekLocal(to: targetTime, completion: completion)
        }
    }

    /// Seek by progress (0.0 – 1.0).
    public func seek(progress: Double, completion: ((Bool) -> Void)? = nil) {
        let clamped = max(0, min(1, progress))
        seek(to: duration * clamped, completion: completion)
    }

    // MARK: - Seek: Local (Pull)

    private func seekLocal(to time: TimeInterval, completion: ((Bool) -> Void)?) {
        guard decoder != nil else {
            completion?(false)
            return
        }

        let thisGeneration: Int = stateQueue.sync {
            isSeeking = true
            seekGeneration += 1
            return seekGeneration
        }

        let wasPlaying = isPlaying

        stopDecoding()
        stopTimeUpdates()
        renderer.stop()

        decodeQueue.async { [weak self] in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisGeneration != self.seekGeneration }
            if stale {
                completion?(false)
                return
            }

            guard let decoder = self.decoder else {
                self.stateQueue.sync { self.isSeeking = false }
                completion?(false)
                return
            }

            do {
                try decoder.seek(to: time)
                self.playbackBaseTime = time
                self.currentTime = time

                if let fmt = self.decoder?.outputFormat {
                    try self.renderer.prepare(format: fmt)
                }

                let stillCurrent: Bool = self.stateQueue.sync {
                    let current = thisGeneration == self.seekGeneration
                    self.isSeeking = false
                    return current
                }

                guard stillCurrent else {
                    completion?(false)
                    return
                }

                if wasPlaying {
                    DispatchQueue.main.async {
                        guard self.state == .playing || self.state == .paused
                                || self.state == .buffering else { return }
                        self.state = .playing
                        self.renderer.rate = self.desiredRate
                        do {
                            try self.renderer.play()
                        } catch {
                            let playerError = VIPlayerError.renderingFailed(error)
                            self.state = .failed(playerError)
                            self.delegate?.player(self, didReceiveError: playerError)
                            return
                        }
                        self.startDecoding()
                        self.startTimeUpdates()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.player(self, didUpdateTime: time, duration: self.duration)
                    }
                }
                completion?(true)
            } catch {
                self.stateQueue.sync { self.isSeeking = false }
                let playerError = VIPlayerError.seekFailed(error)
                self.state = .failed(playerError)
                DispatchQueue.main.async {
                    self.delegate?.player(self, didReceiveError: playerError)
                }
                completion?(false)
            }
        }
    }

    // MARK: - Seek: Network (Push)

    private func seekNetwork(to time: TimeInterval, completion: ((Bool) -> Void)?) {
        guard let sd = streamDecoder, let ps = pushSource else {
            completion?(false)
            return
        }

        let wasPlaying = isPlaying || playWhenReady

        stateQueue.sync {
            seekGeneration += 1
            networkBufferedDuration = 0
        }

        renderer.stop()
        bufferQueue.reset()
        streamEndReached = false
        bufferingReason = .afterSeek

        let byteOffset = sd.seekOffset(for: time) ?? 0

        // Reset stream decoder for a discontinuity
        sd.resetForSeek()

        if let cl = ps.contentLength {
            sd.contentLength = cl
        }

        playbackBaseTime = time
        currentTime = time

        if wasPlaying {
            playWhenReady = true
            state = .buffering
        } else {
            state = .buffering
        }

        // Seek the push source to the byte offset
        ps.seek(to: byteOffset)

        // Prepare renderer if format is already known (don't play yet, checkBufferingToPlaying handles transition)
        if let fmt = sd.outputFormat {
            try? renderer.prepare(format: fmt)
            renderer.rate = desiredRate
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.player(self, didUpdateTime: time, duration: self.duration)
        }
        completion?(true)
    }

    // MARK: - Cache management (forwarded)

    /// Query the cache status of a URL (none / partial / complete).
    public func cacheStatus(for url: URL) -> VICacheStatus {
        downloader.cacheStatus(for: url)
    }

    /// Returns the file URL if the resource is fully cached, otherwise nil.
    public func completeCacheURL(for url: URL) -> URL? {
        downloader.completeCacheURL(for: url)
    }

    /// Returns the cache directory for the given URL.
    /// Each URL maps to its own subdirectory under `cacheDirectory`.
    /// Returns nil if the URL has never been cached.
    public func cachePath(for url: URL) -> URL? {
        let key = configuration.downloaderConfiguration.cacheKey(for: url)
        let dir = cacheDirectory.appendingPathComponent(key, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Remove cached data for a specific URL.
    public func removeCache(for url: URL) {
        downloader.removeCache(for: url)
    }

    /// Remove all cached audio data.
    public func removeAllCache() {
        downloader.removeAllCache()
    }

    /// The root directory where all cached audio files are stored.
    public var cacheDirectory: URL {
        configuration.downloaderConfiguration.cacheDirectory
    }

    // MARK: - Decode thread (Pull mode only)

    private func startDecoding() {
        shouldStopDecoding = false
        bufferQueue.reset()
        decodeQueue.async { [weak self] in
            self?.decodeLoop()
        }
    }

    private func stopDecoding() {
        shouldStopDecoding = true
        bufferQueue.flush()
    }

    private func decodeLoop() {
        guard let decoder = decoder else {
            VILogger.debug("[VIAudioPlayer] decodeLoop: decoder is nil, aborting")
            return
        }
        let format = decoder.outputFormat
        VILogger.debug("[VIAudioPlayer] decodeLoop started, format: \(format)")

        while !shouldStopDecoding {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: configuration.framesPerBuffer
            ) else {
                VILogger.debug("[VIAudioPlayer] decodeLoop: failed to create PCM buffer")
                break
            }

            do {
                let hasMore = try decoder.decode(into: buffer)
                guard buffer.frameLength > 0 else {
                    if !hasMore {
                        VILogger.debug("[VIAudioPlayer] decodeLoop: end of stream reached")
                        feedRenderer()
                        waitForPlaybackFinish()
                        break
                    }
                    continue
                }

                let enqueued = bufferQueue.enqueue(buffer)
                if !enqueued {
                    VILogger.debug("[VIAudioPlayer] decodeLoop: enqueue returned false (flushing or stopped)")
                    break
                }

                feedRenderer()

                if !hasMore {
                    VILogger.debug("[VIAudioPlayer] decodeLoop: last buffer decoded, draining")
                    feedRenderer()
                    waitForPlaybackFinish()
                    break
                }
            } catch {
                if !shouldStopDecoding {
                    VILogger.debug("[VIAudioPlayer] decodeLoop error: \(error)")
                    let playerError = VIPlayerError.decodingFailed(error)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.state = .failed(playerError)
                        self.delegate?.player(self, didReceiveError: playerError)
                    }
                }
                break
            }
        }
        VILogger.debug("[VIAudioPlayer] decodeLoop exited, shouldStop=\(shouldStopDecoding)")
    }

    // MARK: - Buffer feeding

    /// Schedule decoded buffers into renderer in small batches.
    /// This avoids monopolizing the main thread when network push produces
    /// many buffers quickly.
    private func feedRenderer(maxBuffers: Int = 8) {
        var scheduled = 0
        while scheduled < maxBuffers, let buffer = bufferQueue.dequeue() {
            renderer.scheduleBuffer(buffer)
            scheduled += 1
        }
    }

    /// Start renderer playback on a dedicated queue so slow system audio calls
    /// (e.g. first AVAudioSession activation) do not block the main thread.
    private func startNetworkRendererAsync() {
        let fmt = streamDecoder?.outputFormat
        renderControlQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .playing else { return }

            if let fmt, !self.renderer.isPrepared {
                do {
                    try self.renderer.prepare(format: fmt)
                } catch {
                    let playerError = VIPlayerError.renderingFailed(error)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.state = .failed(playerError)
                        self.delegate?.player(self, didReceiveError: playerError)
                    }
                    return
                }
            }

            self.renderer.rate = self.desiredRate
            self.feedRenderer()
            do {
                try self.renderer.play()
            } catch {
                let playerError = VIPlayerError.renderingFailed(error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state = .failed(playerError)
                    self.delegate?.player(self, didReceiveError: playerError)
                }
            }
        }
    }

    private func waitForPlaybackFinish() {
        while renderer.scheduledBufferCount > 0 && !shouldStopDecoding {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !shouldStopDecoding else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // For network mode, only finish if the stream truly ended
            if self.isNetworkMode && !self.streamEndReached { return }
            self.state = .finished
            self.stopTimeUpdates()
        }
    }

    // MARK: - Buffering state machine (Network mode)

    /// Called after a buffer is enqueued (network push path).
    /// Checks whether we have enough buffered audio to transition from
    /// `.buffering` to `.playing`. Must be called on the main queue.
    private func checkBufferingToPlaying() {
        guard isNetworkMode, state == .buffering, playWhenReady else { return }

        let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
        let required = requiredBufferDuration()
        let enoughData = accumulated >= required || (streamEndReached && accumulated > 0)

        guard enoughData else { return }

        bufferingReason = nil
        state = .playing
        startNetworkRendererAsync()
        VILogger.debug("[VIAudioPlayer] buffering → playing (accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s scheduled=\(renderer.scheduledBufferCount))")
    }

    /// Check if stream has ended and all buffers consumed.
    private func checkStreamFinished() {
        guard isNetworkMode, streamEndReached else { return }
        guard bufferQueue.isEmpty, renderer.scheduledBufferCount == 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.streamEndReached, self.bufferQueue.isEmpty,
               self.renderer.scheduledBufferCount == 0,
               self.state == .playing || self.state == .buffering {
                self.state = .finished
                self.stopTimeUpdates()
            }
        }
    }

    /// Returns the required buffer duration before starting/resuming playback.
    private func requiredBufferDuration() -> TimeInterval {
        switch bufferingReason {
        case .initialLoad:
            return configuration.secondsRequiredToStartPlaying
        case .afterSeek:
            return configuration.secondsRequiredAfterSeek
        case .underrun:
            return configuration.secondsRequiredAfterBufferUnderrun
        case .none:
            return configuration.secondsRequiredToStartPlaying
        }
    }

    /// Called periodically to detect buffer underruns (network mode).
    private func checkForBufferUnderrun() {
        guard isNetworkMode, state == .playing else { return }
        guard !streamEndReached else { return }

        if renderer.scheduledBufferCount == 0 && bufferQueue.isEmpty {
            VILogger.debug("[VIAudioPlayer] buffer underrun detected, entering buffering state")
            let rendererTime = renderer.currentPlaybackTime
            playbackBaseTime += rendererTime
            renderer.stop()
            stateQueue.sync { networkBufferedDuration = 0 }
            bufferingReason = .underrun
            state = .buffering
            notifyBufferState()
        }
    }

    // MARK: - Time updates

    private func startTimeUpdates() {
        stopTimeUpdates()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: configuration.timeUpdateInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            if self.state == .playing {
                self.updateCurrentTime()
                self.checkForBufferUnderrun()
                if self.isNetworkMode {
                    self.checkStreamFinished()
                    self.notifyBufferState()
                }
            } else if self.state == .buffering {
                self.checkBufferingToPlaying()
                if self.isNetworkMode { self.notifyBufferState() }
            }
        }
        timer.resume()
        self.timeUpdateTimer = timer
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    private func updateCurrentTime() {
        let seeking: Bool = stateQueue.sync { isSeeking }
        guard !seeking else { return }

        // Lazily pick up duration from the stream decoder when ours is still 0
        // (bitrate may arrive after onOutputFormatReady).
        if duration == 0, let sd = streamDecoder, sd.duration > 0 {
            duration = sd.duration
        }

        let rendererTime = renderer.currentPlaybackTime
        let time = playbackBaseTime + rendererTime
        let clampedTime = duration > 0 ? min(time, duration) : time
        guard clampedTime.isFinite else { return }
        currentTime = clampedTime
        delegate?.player(self, didUpdateTime: clampedTime, duration: duration)
    }

    // MARK: - Buffer state notification

    /// Must be called on the main queue (from the timer handler).
    private func notifyBufferState() {
        guard isNetworkMode else { return }

        let bufferState: VIBufferState
        if streamEndReached {
            bufferState = .full
        } else {
            let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
            let required = requiredBufferDuration()
            if accumulated <= 0 {
                bufferState = .empty
            } else if accumulated >= required {
                bufferState = .sufficient
            } else {
                let progress = Float(accumulated / required)
                bufferState = .buffering(progress: min(progress, 1.0))
            }
        }

        delegate?.player(self, didUpdateBuffer: bufferState)
    }

    // MARK: - Helpers

    private func wrapError(_ error: Error) -> VIPlayerError {
        if let pe = error as? VIPlayerError { return pe }
        if let se = error as? VIAudioSourceError { return .networkError(se) }
        return .decoderCreationFailed(error)
    }
}
