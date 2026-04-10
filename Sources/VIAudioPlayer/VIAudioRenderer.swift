import AVFoundation
import os
#if !COCOAPODS
import VIAudioDownloader
#endif

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
    /// Uses os_unfair_lock for the hot path (scheduleBuffer completion on audio render thread)
    /// to avoid priority inversion that NSLock can cause.
    private var _lock = os_unfair_lock()
    /// Separate NSLock for prepare/teardown (longer critical sections where os_unfair_lock is inappropriate).
    private let engineLock = NSLock()
    private var isEngineRunning = false
    private var nodesAttached = false
    private var _isPrepared = false
    private var isAudioSessionConfigured = false

    /// Whether the renderer has been prepared with a format and the engine is running.
    public var isPrepared: Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return _isPrepared && isEngineRunning
    }

    /// Called on the render thread when the player node finishes a buffer
    /// and may need more data.
    public var onNeedsData: VIRendererNeedsDataHandler?

    /// Called when an audio session interruption begins or ends.
    /// `true` = interruption began (paused), `false` = interruption ended (may resume).
    public var onInterruption: ((_ began: Bool) -> Void)?

    /// Number of buffers currently scheduled in the player node.
    public private(set) var scheduledBufferCount: Int = 0

    /// playerNode 当前是否在播放（用于中断恢复后的状态同步）
    public var isNodePlaying: Bool { playerNode.isPlaying }

    // MARK: - Rate

    public var rate: Float {
        get {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return _rate
        }
        set {
            os_unfair_lock_lock(&_lock)
            _rate = newValue
            os_unfair_lock_unlock(&_lock)
            timePitchNode.rate = newValue
        }
    }

    // MARK: - Setup

    /// Prepare the engine graph for the given format.
    /// Safe to call multiple times — skips if already prepared with the same format.
    public func prepare(format: AVAudioFormat) throws {
        engineLock.lock()
        defer { engineLock.unlock() }

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
        os_unfair_lock_lock(&_lock)
        scheduledBufferCount += 1
        os_unfair_lock_unlock(&_lock)

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self._lock)
            self.scheduledBufferCount -= 1
            let count = self.scheduledBufferCount
            os_unfair_lock_unlock(&self._lock)

            if count <= 2 {
                self.onNeedsData?()
            }
        }
    }

    // MARK: - Playback control

    public func play() throws {
        configureAudioSessionIfNeeded()
        if !isEngineRunning {
            try engine.start()
            isEngineRunning = true
        }
        playerNode.play()
    }

    public func pause() {
        playerNode.pause()
    }

    public func stop() {
        playerNode.stop()
        os_unfair_lock_lock(&_lock)
        scheduledBufferCount = 0
        os_unfair_lock_unlock(&_lock)
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
        engineLock.lock()
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
        os_unfair_lock_lock(&_lock)
        scheduledBufferCount = 0
        os_unfair_lock_unlock(&_lock)
        scheduledFormat = nil
        _isPrepared = false
        #if os(iOS) || os(tvOS)
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        isAudioSessionConfigured = false
        #endif
        engineLock.unlock()
    }

    // MARK: - Audio session (iOS / tvOS)

    private var interruptionObserver: NSObjectProtocol?

    private func configureAudioSessionIfNeeded() {
        #if os(iOS) || os(tvOS)
        guard !isAudioSessionConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            isAudioSessionConfigured = true
        } catch {
            VILogger.debug("[VIAudioRenderer] AudioSession configuration failed: \(error)")
        }
        registerInterruptionObserver()
        #endif
    }

    private func registerInterruptionObserver() {
        #if os(iOS) || os(tvOS)
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        #endif
    }

    private func handleInterruption(_ notification: Notification) {
        #if os(iOS) || os(tvOS)
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            VILogger.debug("[VIAudioRenderer] Audio session interruption began")
            playerNode.pause()
            onInterruption?(true)

        case .ended:
            VILogger.debug("[VIAudioRenderer] Audio session interruption ended")
            let shouldResume: Bool
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    .contains(.shouldResume)
            } else {
                shouldResume = false
            }

            if shouldResume {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    if !isEngineRunning {
                        try engine.start()
                        isEngineRunning = true
                    }
                    playerNode.play()
                } catch {
                    VILogger.error("[VIAudioRenderer] Failed to resume after interruption: \(error)")
                }
            }
            onInterruption?(false)

        @unknown default:
            break
        }
        #endif
    }
}
