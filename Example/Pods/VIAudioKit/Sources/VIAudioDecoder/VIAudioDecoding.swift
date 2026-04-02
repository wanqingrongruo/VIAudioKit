import AVFoundation

/// Errors produced by audio decoders.
public enum VIDecoderError: Error, Sendable {
    case unsupportedFormat(String)
    case fileOpenFailed(OSStatus)
    case decodeFailed(OSStatus)
    case seekFailed(OSStatus)
    case endOfStream
    case sourceUnavailable
}

/// Protocol for pluggable audio decoders. Any format can be supported by
/// providing a conforming type.
///
/// Implementations must be usable from a dedicated decode thread.
public protocol VIAudioDecoding: AnyObject {

    /// File extensions this decoder handles (lowercase, without dot), e.g. `["mp3", "aac"]`.
    static var supportedExtensions: Set<String> { get }

    /// Create a decoder for the given audio source.
    /// - Parameter source: Abstraction over local file or network-backed data.
    init(source: VIAudioSource) throws

    /// The PCM format that `decode(into:)` will produce.
    var outputFormat: AVAudioFormat { get }

    /// Total duration in seconds. May be approximate for VBR / streaming sources.
    var duration: TimeInterval { get }

    /// Current decode position in seconds.
    var currentTime: TimeInterval { get }

    /// Decode the next chunk of audio into `buffer`.
    /// - Returns: `true` if more data is available, `false` at end of stream.
    func decode(into buffer: AVAudioPCMBuffer) throws -> Bool

    /// Seek to the given time. The next `decode(into:)` call will produce
    /// audio from (approximately) that position.
    func seek(to time: TimeInterval) throws

    /// Release resources. Safe to call multiple times.
    func close()
}
