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
    private var streamDecoder: VIStreamDecoder?
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
    private let lock = NSLock()

    /// Registry of decoder types. Add custom decoders here.
    public var decoderTypes: [VIAudioDecoding.Type] = [VINativeDecoder.self]

    // MARK: - Init

    public init(configuration: VIPlayerConfiguration = VIPlayerConfiguration()) {
        self.configuration = configuration
        self.downloader = VIChunkedDownloader(configuration: configuration.downloaderConfiguration)
        self.bufferQueue = VIAudioBufferQueue(capacity: configuration.decodeBufferCount)

        renderer.onNeedsData = { [weak self] in
            self?.feedRenderer()
        }
    }

    public init(configuration: VIPlayerConfiguration = VIPlayerConfiguration(),
                downloader: VIChunkedDownloader) {
        self.configuration = configuration
        self.downloader = downloader
        self.bufferQueue = VIAudioBufferQueue(capacity: configuration.decodeBufferCount)

        renderer.onNeedsData = { [weak self] in
            self?.feedRenderer()
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

        lock.lock()
        loadGeneration += 1
        let thisLoad = loadGeneration
        lock.unlock()

        state = .preparing

        debugPrint("[VIAudioPlayer] load: \(url.lastPathComponent) isFile=\(url.isFileURL)")

        if url.isFileURL {
            isNetworkMode = false
            loadLocalFile(url: url, extensionHint: nil, thisLoad: thisLoad)
        } else {
            if let cachedURL = downloader.completeCacheURL(for: url) {
                debugPrint("[VIAudioPlayer] load: fully cached, using local file path")
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

            self.lock.lock()
            let stale = thisLoad != self.loadGeneration
            self.lock.unlock()
            guard !stale else {
                debugPrint("[VIAudioPlayer] load: stale (generation \(thisLoad)), skipping")
                return
            }

            do {
                let source = try VILocalFileSource(fileURL: url)
                self.source = source

                let ext = (extensionHint?.isEmpty == false) ? extensionHint! : source.fileExtension
                debugPrint("[VIAudioPlayer] load: ext=\(ext) size=\(source.contentLength ?? -1)")

                guard let decoderType = self.decoderTypes.first(where: {
                    $0.supportedExtensions.contains(ext)
                }) else {
                    throw VIPlayerError.decoderCreationFailed(
                        VIDecoderError.unsupportedFormat(ext)
                    )
                }

                let decoder = try decoderType.init(source: source)

                self.lock.lock()
                let staleAfterDecode = thisLoad != self.loadGeneration
                self.lock.unlock()
                if staleAfterDecode {
                    decoder.close()
                    debugPrint("[VIAudioPlayer] load: stale after decode init, skipping")
                    return
                }

                self.decoder = decoder
                self.duration = decoder.duration

                debugPrint("[VIAudioPlayer] load: decoder ready, duration=\(String(format: "%.2f", decoder.duration))s")
                try self.renderer.prepare(format: decoder.outputFormat)
                debugPrint("[VIAudioPlayer] load: renderer prepared, setting state=ready")
                self.state = .ready
            } catch {
                self.lock.lock()
                let stillCurrent = thisLoad == self.loadGeneration
                self.lock.unlock()
                guard stillCurrent else { return }

                debugPrint("[VIAudioPlayer] load failed: \(error)")
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
        let sd = VIStreamDecoder()
        sd.framesPerBuffer = configuration.framesPerBuffer

        self.pushSource = ps
        self.streamDecoder = sd

        let hint = VIStreamDecoder.fileTypeHint(for: ext)
        do {
            try sd.open(fileTypeHint: hint)
        } catch {
            debugPrint("[VIAudioPlayer] load: stream decoder open failed: \(error)")
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
            guard let sd else { return }
            sd.contentLength = length
            sd.updateDuration()
            if let self, sd.duration > 0 {
                self.duration = sd.duration
                debugPrint("[VIAudioPlayer] duration updated from content length: \(String(format: "%.2f", sd.duration))s")
            }
        }

        var dataChunkCount = 0
        ps.onDataReceived = { [weak self, weak sd] data in
            guard let self, let sd else { return }

            self.lock.lock()
            let stale = thisLoad != self.loadGeneration
            self.lock.unlock()
            guard !stale else { return }

            dataChunkCount += 1
            if dataChunkCount <= 5 || dataChunkCount % 50 == 0 {
                debugPrint("[VIAudioPlayer] onDataReceived #\(dataChunkCount): \(data.count) bytes, total fed to decoder=\(sd.totalBytesReceived + Int64(data.count))")
            }
            sd.feed(data)
        }

        sd.onOutputFormatReady = { [weak self] format, dur in
            guard let self else { return }

            self.lock.lock()
            let stale = thisLoad != self.loadGeneration
            self.lock.unlock()
            guard !stale else { return }

            if dur > 0 {
                self.duration = dur
            }
            do {
                try self.renderer.prepare(format: format)
            } catch {
                debugPrint("[VIAudioPlayer] renderer prepare failed: \(error)")
            }
            debugPrint("[VIAudioPlayer] load(network): format ready, duration=\(String(format: "%.2f", self.duration))s")
        }

        var bufferReadyCount = 0
        sd.onBufferReady = { [weak self] buffer in
            guard let self else { return }

            self.lock.lock()
            let stale = thisLoad != self.loadGeneration
            self.lock.unlock()
            guard !stale else { return }

            let rate = buffer.format.sampleRate
            let bufDur = rate > 0 ? Double(buffer.frameLength) / rate : 0
            self.lock.lock()
            self.networkBufferedDuration += bufDur
            let accumulated = self.networkBufferedDuration
            self.lock.unlock()

            bufferReadyCount += 1
            if bufferReadyCount <= 5 || bufferReadyCount % 50 == 0 {
                debugPrint("[VIAudioPlayer] onBufferReady #\(bufferReadyCount): frames=\(buffer.frameLength) state=\(self.state) accumulated=\(String(format: "%.2f", accumulated))s")
            }

            if self.state == .playing {
                self.renderer.scheduleBuffer(buffer)
            } else {
                // Buffering: try non-blocking enqueue; if queue full, schedule directly to renderer.
                if !self.bufferQueue.tryEnqueue(buffer) {
                    self.renderer.scheduleBuffer(buffer)
                }
                self.checkBufferingToPlaying()
            }
        }

        sd.onEndOfStream = { [weak self] in
            guard let self else { return }
            self.streamEndReached = true
            self.feedRenderer()
            self.checkStreamFinished()
        }

        sd.onError = { error in
            debugPrint("[VIAudioPlayer] stream decoder error: \(error)")
        }

        ps.onWaitingForNetworkChanged = { waiting in
            if waiting {
                debugPrint("[VIAudioPlayer] waiting for network…")
            } else {
                debugPrint("[VIAudioPlayer] network recovered")
            }
        }

        ps.onEndOfFile = { [weak self] in
            guard let self else { return }
            debugPrint("[VIAudioPlayer] push source: end of file")
            self.streamEndReached = true
            self.streamDecoder?.flush()
            self.feedRenderer()
            self.checkBufferingToPlaying()
            self.checkStreamFinished()
        }

        ps.onError = { [weak self] error in
            guard let self else { return }
            debugPrint("[VIAudioPlayer] push source fatal error: \(error)")
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
        if isNetworkMode {
            playWhenReady = true
            // Accept play() in any state for network mode (including preparing/buffering)
            guard state == .ready || state == .paused || state == .buffering || state == .preparing else { return }
            pushSource?.resume()

            lock.lock()
            let accumulated = networkBufferedDuration
            lock.unlock()
            let required = requiredBufferDuration()
            debugPrint("[VIAudioPlayer] play(): network mode, accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s streamEnd=\(streamEndReached)")

            if accumulated >= required || (streamEndReached && accumulated > 0) {
                state = .playing
                if let fmt = streamDecoder?.outputFormat {
                    try? renderer.prepare(format: fmt)
                }
                renderer.rate = desiredRate
                feedRenderer()
                renderer.play()
                bufferingReason = nil
                debugPrint("[VIAudioPlayer] play(): immediate transition to playing")
            } else {
                if state != .buffering {
                    bufferingReason = .initialLoad
                    state = .buffering
                }
            }
            startTimeUpdates()
            return
        }

        guard state == .ready || state == .paused else { return }
        state = .playing
        renderer.rate = desiredRate
        renderer.play()
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

        lock.lock()
        isSeeking = true
        seekGeneration += 1
        let thisGeneration = seekGeneration
        lock.unlock()

        let wasPlaying = isPlaying

        stopDecoding()
        stopTimeUpdates()
        renderer.stop()

        decodeQueue.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let stale = thisGeneration != self.seekGeneration
            self.lock.unlock()
            if stale {
                completion?(false)
                return
            }

            guard let decoder = self.decoder else {
                self.lock.lock()
                self.isSeeking = false
                self.lock.unlock()
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

                self.lock.lock()
                let stillCurrent = thisGeneration == self.seekGeneration
                self.isSeeking = false
                self.lock.unlock()

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
                        self.renderer.play()
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
                self.lock.lock()
                self.isSeeking = false
                self.lock.unlock()
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

        lock.lock()
        seekGeneration += 1
        lock.unlock()

        renderer.stop()
        bufferQueue.reset()
        streamEndReached = false
        bufferingReason = .afterSeek
        lock.lock()
        networkBufferedDuration = 0
        lock.unlock()

        let byteOffset = sd.seekOffset(for: time) ?? 0

        // Reset stream decoder and reopen
        let hint = VIStreamDecoder.fileTypeHint(for: networkFileExt)
        sd.reset()
        do {
            try sd.open(fileTypeHint: hint)
        } catch {
            debugPrint("[VIAudioPlayer] seekNetwork: stream decoder reopen failed: \(error)")
            completion?(false)
            return
        }

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
            debugPrint("[VIAudioPlayer] decodeLoop: decoder is nil, aborting")
            return
        }
        let format = decoder.outputFormat
        debugPrint("[VIAudioPlayer] decodeLoop started, format: \(format)")

        while !shouldStopDecoding {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: configuration.framesPerBuffer
            ) else {
                debugPrint("[VIAudioPlayer] decodeLoop: failed to create PCM buffer")
                break
            }

            do {
                let hasMore = try decoder.decode(into: buffer)
                guard buffer.frameLength > 0 else {
                    if !hasMore {
                        debugPrint("[VIAudioPlayer] decodeLoop: end of stream reached")
                        drainBufferQueue()
                        waitForPlaybackFinish()
                        break
                    }
                    continue
                }

                let enqueued = bufferQueue.enqueue(buffer)
                if !enqueued {
                    debugPrint("[VIAudioPlayer] decodeLoop: enqueue returned false (flushing or stopped)")
                    break
                }

                feedRenderer()

                if !hasMore {
                    debugPrint("[VIAudioPlayer] decodeLoop: last buffer decoded, draining")
                    drainBufferQueue()
                    waitForPlaybackFinish()
                    break
                }
            } catch {
                if !shouldStopDecoding {
                    debugPrint("[VIAudioPlayer] decodeLoop error: \(error)")
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
        debugPrint("[VIAudioPlayer] decodeLoop exited, shouldStop=\(shouldStopDecoding)")
    }

    // MARK: - Buffer feeding

    private func feedRenderer() {
        while let buffer = bufferQueue.dequeue() {
            renderer.scheduleBuffer(buffer)
        }
    }

    private func drainBufferQueue() {
        while let buffer = bufferQueue.dequeue() {
            renderer.scheduleBuffer(buffer)
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
    /// `.buffering` to `.playing`.
    private func checkBufferingToPlaying() {
        guard isNetworkMode, state == .buffering, playWhenReady else { return }

        lock.lock()
        let accumulated = networkBufferedDuration
        lock.unlock()

        let required = requiredBufferDuration()
        let enoughData = accumulated >= required || (streamEndReached && accumulated > 0)

        if enoughData {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state == .buffering else { return }
                self.bufferingReason = nil
                self.state = .playing
                if let fmt = self.streamDecoder?.outputFormat {
                    try? self.renderer.prepare(format: fmt)
                }
                self.renderer.rate = self.desiredRate
                self.feedRenderer()
                self.renderer.play()
                debugPrint("[VIAudioPlayer] buffering → playing (accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s scheduled=\(self.renderer.scheduledBufferCount))")
            }
        }
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
            debugPrint("[VIAudioPlayer] buffer underrun detected, entering buffering state")
            let rendererTime = renderer.currentPlaybackTime
            playbackBaseTime += rendererTime
            renderer.stop()
            lock.lock()
            networkBufferedDuration = 0
            lock.unlock()
            bufferingReason = .underrun
            state = .buffering
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
                if self.isNetworkMode { self.checkStreamFinished() }
            } else if self.state == .buffering {
                self.checkBufferingToPlaying()
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
        lock.lock()
        let seeking = isSeeking
        lock.unlock()
        guard !seeking else { return }

        let rendererTime = renderer.currentPlaybackTime
        let time = playbackBaseTime + rendererTime
        let clampedTime = min(time, duration)
        guard clampedTime.isFinite else { return }
        currentTime = clampedTime
        delegate?.player(self, didUpdateTime: clampedTime, duration: duration)
    }

    // MARK: - Helpers

    private func wrapError(_ error: Error) -> VIPlayerError {
        if let pe = error as? VIPlayerError { return pe }
        if let se = error as? VIAudioSourceError { return .networkError(se) }
        return .decoderCreationFailed(error)
    }
}
