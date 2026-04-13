import Foundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
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

    // MARK: - Decoder selection

    /// 为特定文件扩展名指定 Pull 模式解码器
    ///
    /// 使用场景：
    /// - 多个解码器支持同一格式时，指定优先使用哪个
    /// - 强制某些格式使用特定解码器
    ///
    /// 示例：
    /// ```swift
    /// config.decoderMapping["ogg"] = VIFFmpegDecoder.self
    /// config.decoderMapping["mp3"] = VINativeDecoder.self
    /// ```
    ///
    /// 如果未指定映射，则使用 `VIAudioPlayer.decoderTypes` 数组顺序匹配
    public var decoderMapping: [String: VIAudioDecoding.Type]

    /// 为特定文件扩展名指定 Push 模式解码器（网络流）
    ///
    /// 示例：
    /// ```swift
    /// config.streamDecoderMapping["opus"] = VIFFmpegStreamDecoder.self
    /// ```
    ///
    /// 如果未指定映射，则使用 `VIAudioPlayer.streamDecoderTypes` 数组顺序匹配
    public var streamDecoderMapping: [String: VIStreamDecoding.Type]

    public init(
        downloaderConfiguration: VIDownloaderConfiguration = VIDownloaderConfiguration(),
        decodeBufferCount: Int = 8,
        framesPerBuffer: UInt32 = 8192,
        timeUpdateInterval: TimeInterval = 0.05,
        secondsRequiredToStartPlaying: TimeInterval = 1.0,
        secondsRequiredAfterSeek: TimeInterval = 0.5,
        secondsRequiredAfterBufferUnderrun: TimeInterval = 3.0,
        decoderMapping: [String: VIAudioDecoding.Type] = [:],
        streamDecoderMapping: [String: VIStreamDecoding.Type] = [:]
    ) {
        self.downloaderConfiguration = downloaderConfiguration
        self.decodeBufferCount = decodeBufferCount
        self.framesPerBuffer = framesPerBuffer
        self.timeUpdateInterval = timeUpdateInterval
        self.secondsRequiredToStartPlaying = secondsRequiredToStartPlaying
        self.secondsRequiredAfterSeek = secondsRequiredAfterSeek
        self.secondsRequiredAfterBufferUnderrun = secondsRequiredAfterBufferUnderrun
        self.decoderMapping = decoderMapping
        self.streamDecoderMapping = streamDecoderMapping
    }
}
