import Foundation
#if !COCOAPODS
import VIAudioDownloader
#endif

/// Configuration for `VIAudioPlayer`.
public struct VIPlayerConfiguration: Sendable {

    /// Downloader configuration (URL canonicalization, cache directory, etc.)
    public var downloaderConfiguration: VIDownloaderConfiguration

    /// Number of PCM buffers to keep decoded ahead of playback.
    /// Higher values = smoother playback but more memory.
    public var decodeBufferCount: Int

    /// Number of audio frames per decode buffer.
    public var framesPerBuffer: UInt32

    /// Minimum decoded duration (seconds) required before playback can start.
    public var minimumBufferDuration: TimeInterval

    /// Interval for time-progress callbacks (seconds).
    public var timeUpdateInterval: TimeInterval

    // MARK: - Network buffering thresholds

    /// Seconds of decoded audio required before initial playback starts (network mode).
    public var secondsRequiredToStartPlaying: TimeInterval

    /// Seconds of decoded audio required after a seek before resuming playback (network mode).
    public var secondsRequiredAfterSeek: TimeInterval

    /// Seconds of decoded audio required after a buffer underrun before resuming (network mode).
    /// Typically larger than `secondsRequiredToStartPlaying` to avoid rapid rebuffering.
    public var secondsRequiredAfterBufferUnderrun: TimeInterval

    public init(
        downloaderConfiguration: VIDownloaderConfiguration = VIDownloaderConfiguration(),
        decodeBufferCount: Int = 8,
        framesPerBuffer: UInt32 = 8192,
        minimumBufferDuration: TimeInterval = 0.5,
        timeUpdateInterval: TimeInterval = 0.05,
        secondsRequiredToStartPlaying: TimeInterval = 1.0,
        secondsRequiredAfterSeek: TimeInterval = 0.5,
        secondsRequiredAfterBufferUnderrun: TimeInterval = 3.0
    ) {
        self.downloaderConfiguration = downloaderConfiguration
        self.decodeBufferCount = decodeBufferCount
        self.framesPerBuffer = framesPerBuffer
        self.minimumBufferDuration = minimumBufferDuration
        self.timeUpdateInterval = timeUpdateInterval
        self.secondsRequiredToStartPlaying = secondsRequiredToStartPlaying
        self.secondsRequiredAfterSeek = secondsRequiredAfterSeek
        self.secondsRequiredAfterBufferUnderrun = secondsRequiredAfterBufferUnderrun
    }
}
