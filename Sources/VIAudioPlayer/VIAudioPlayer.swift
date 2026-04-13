import Foundation
import AVFoundation
import os
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
enum BufferingReason {
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

    /// 保护 _state / _currentTime / _duration / _shouldStopDecoding 的读写。
    /// 使用 os_unfair_lock 是因为这些属性在音频热路径（renderer 回调）中被读取，
    /// 需要避免 NSLock 可能引起的优先级反转。
    private var _playerLock = os_unfair_lock()

    private var _state: VIPlayerState = .idle
    public var state: VIPlayerState {
        get {
            os_unfair_lock_lock(&_playerLock)
            defer { os_unfair_lock_unlock(&_playerLock) }
            return _state
        }
        set {
            os_unfair_lock_lock(&_playerLock)
            let oldValue = _state
            _state = newValue
            os_unfair_lock_unlock(&_playerLock)
            guard newValue != oldValue else { return }
            let captured = newValue
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didChangeState: captured)
            }
        }
    }

    private var _currentTime: TimeInterval = 0
    public var currentTime: TimeInterval {
        get {
            os_unfair_lock_lock(&_playerLock)
            defer { os_unfair_lock_unlock(&_playerLock) }
            return _currentTime
        }
        set {
            os_unfair_lock_lock(&_playerLock)
            _currentTime = newValue
            os_unfair_lock_unlock(&_playerLock)
        }
    }

    private var _duration: TimeInterval = 0
    public var duration: TimeInterval {
        get {
            os_unfair_lock_lock(&_playerLock)
            defer { os_unfair_lock_unlock(&_playerLock) }
            return _duration
        }
        set {
            os_unfair_lock_lock(&_playerLock)
            _duration = newValue
            os_unfair_lock_unlock(&_playerLock)
        }
    }

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

    let downloader: VIChunkedDownloader
    let renderer = VIAudioRenderer()
    let bufferQueue: VIAudioBufferQueue

    // Pull-mode (local files)
    var decoder: VIAudioDecoding?
    var source: VIAudioSource?

    // Push-mode (network files)
    var streamDecoder: VIStreamDecoding?
    var pushSource: VIPushAudioSource?
    var isNetworkMode = false
    var networkFileExt: String = ""

    var currentURL: URL?
    var desiredRate: Float = 1.0
    var isSeeking = false
    private var _shouldStopDecoding = false
    var shouldStopDecoding: Bool {
        get {
            os_unfair_lock_lock(&_playerLock)
            defer { os_unfair_lock_unlock(&_playerLock) }
            return _shouldStopDecoding
        }
        set {
            os_unfair_lock_lock(&_playerLock)
            _shouldStopDecoding = newValue
            os_unfair_lock_unlock(&_playerLock)
        }
    }
    var seekGeneration: Int = 0
    var loadGeneration: Int = 0

    /// The audio-time offset at which the current play/seek segment started.
    var playbackBaseTime: TimeInterval = 0

    /// Whether the user requested play (even while in buffering state).
    public internal(set) var playWhenReady = false

    /// Tracks why we're in buffering state (to pick the right threshold).
    var bufferingReason: BufferingReason?

    /// Set to true when the stream decoder signaled end-of-stream (all data pushed).
    var streamEndReached = false

    /// Total decoded audio duration accumulated since the last buffering start (network mode).
    /// Incremented by every `onBufferReady` callback; reset on load/seek/underrun.
    var networkBufferedDuration: TimeInterval = 0

    var timeUpdateTimer: DispatchSourceTimer?
    let decodeQueue = DispatchQueue(label: "com.viaudiokit.decode", qos: .userInitiated)
    let pushQueue = DispatchQueue(label: "com.viaudiokit.push", qos: .userInitiated)
    let renderControlQueue = DispatchQueue(label: "com.viaudiokit.render.control", qos: .userInitiated)
    /// Serial queue protecting all mutable state that is read/written across threads
    /// (generation counters, isSeeking, networkBufferedDuration, etc.).
    let stateQueue = DispatchQueue(label: "com.viaudiokit.player.state")

    /// Registry of pull-mode decoder types. Add custom decoders here.
    public var decoderTypes: [VIAudioDecoding.Type] = [VINativeDecoder.self, VIMixingDecoder.self]

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

    func setupRendererCallbacks() {
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
            } else {
                // 中断结束：renderer 已根据 shouldResume 决定是否恢复 playerNode
                // 通过 isNodePlaying 确认 renderer 是否真的恢复了，再同步 Player 状态
                if self.playWhenReady && self.renderer.isNodePlaying {
                    self.playWhenReady = false
                    self.state = .playing
                    self.startTimeUpdates()
                } else {
                    // shouldResume 为 false 或 renderer 恢复失败，清除标记，等待用户手动恢复
                    self.playWhenReady = false
                }
            }
        }
    }

    deinit {
        stop()
    }

}
