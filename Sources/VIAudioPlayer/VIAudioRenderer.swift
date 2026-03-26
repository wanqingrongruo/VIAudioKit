import AVFoundation

/// Callback when the renderer needs more data scheduled.
public typealias VIRendererNeedsDataHandler = () -> Void

/// Wraps AVAudioEngine with a player node and optional time-pitch node.
/// Handles buffer scheduling, playback rate, and engine lifecycle.
public final class VIAudioRenderer: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()

    private var scheduledFormat: AVAudioFormat?
    private var _rate: Float = 1.0
    private let lock = NSLock()
    private var isEngineRunning = false
    private var nodesAttached = false
    private var _isPrepared = false

    /// Whether the renderer has been prepared with a format and the engine is running.
    public var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isPrepared && isEngineRunning
    }

    /// Called on the render thread when the player node finishes a buffer
    /// and may need more data.
    public var onNeedsData: VIRendererNeedsDataHandler?

    /// Number of buffers currently scheduled in the player node.
    public private(set) var scheduledBufferCount: Int = 0

    // MARK: - Rate

    public var rate: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _rate
        }
        set {
            lock.lock()
            _rate = newValue
            lock.unlock()
            timePitchNode.rate = newValue
        }
    }

    // MARK: - Setup

    /// Prepare the engine graph for the given format.
    /// Safe to call multiple times — skips if already prepared with the same format.
    public func prepare(format: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }

        if _isPrepared, isEngineRunning, scheduledFormat == format {
            return
        }

        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }

        if !nodesAttached {
            engine.attach(playerNode)
            engine.attach(timePitchNode)
            nodesAttached = true
        }

        engine.connect(playerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: format)

        engine.prepare()
        try engine.start()
        isEngineRunning = true
        _isPrepared = true
        scheduledFormat = format
        timePitchNode.rate = _rate
    }

    // MARK: - Schedule buffers

    /// Schedule a PCM buffer for playback.
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        scheduledBufferCount += 1
        lock.unlock()

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduledBufferCount -= 1
            let count = self.scheduledBufferCount
            self.lock.unlock()

            if count <= 2 {
                self.onNeedsData?()
            }
        }
    }

    // MARK: - Playback control

    public func play() {
        configureAudioSession()
        if !isEngineRunning {
            try? engine.start()
            isEngineRunning = true
        }
        playerNode.play()
    }

    public func pause() {
        playerNode.pause()
    }

    public func stop() {
        playerNode.stop()
        lock.lock()
        scheduledBufferCount = 0
        lock.unlock()
    }

    /// Current playback time based on the player node's sample time.
    public var currentSampleTime: AVAudioTime? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime
    }

    /// Current playback time in seconds relative to the player node.
    public var currentPlaybackTime: TimeInterval {
        guard let time = currentSampleTime else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    // MARK: - Teardown

    public func teardown() {
        lock.lock()
        playerNode.stop()
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
        if nodesAttached {
            engine.detach(timePitchNode)
            engine.detach(playerNode)
            nodesAttached = false
        }
        scheduledBufferCount = 0
        scheduledFormat = nil
        _isPrepared = false
        lock.unlock()
    }

    // MARK: - Audio session (iOS only)

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            debugPrint("[VIAudioRenderer] AudioSession configuration failed: \(error)")
        }
        #endif
    }
}
