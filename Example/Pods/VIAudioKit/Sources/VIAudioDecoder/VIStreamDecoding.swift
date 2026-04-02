import AVFoundation
import AudioToolbox

/// Protocol for push-based audio stream decoders.
///
/// Unlike the pull-based `VIAudioDecoding` protocol (which blocks on `decode(into:)`),
/// conforming types receive raw data via `feed(_:)` and deliver decoded PCM
/// buffers asynchronously through callbacks.
///
/// `VIStreamDecoder` is the default implementation backed by AudioFileStream + AudioConverter.
/// Implement this protocol to provide alternative push-mode decoders (e.g., Opus, custom codecs).
public protocol VIStreamDecoding: AnyObject {

    // MARK: - Callbacks

    /// File extensions this decoder handles (lowercase, without dot), e.g. `["mp3", "aac"]`.
    static var supportedExtensions: Set<String> { get }

    /// Called when the output PCM format and estimated duration become available.
    var onOutputFormatReady: ((_ format: AVAudioFormat, _ duration: TimeInterval) -> Void)? { get set }

    /// Called each time a decoded PCM buffer is ready for scheduling.
    var onBufferReady: ((_ buffer: AVAudioPCMBuffer) -> Void)? { get set }

    /// Called when the decoder has produced all buffers for the current stream.
    var onEndOfStream: (() -> Void)? { get set }

    /// Called on non-recoverable decode errors.
    var onError: ((_ error: Error) -> Void)? { get set }

    // MARK: - Properties

    /// The discovered output PCM format, or `nil` if not yet known.
    var outputFormat: AVAudioFormat? { get }

    /// Estimated total duration of the audio stream.
    var duration: TimeInterval { get }

    /// Total content length in bytes (set by the caller once known from the server response).
    var contentLength: Int64 { get set }

    /// Number of PCM frames per output buffer.
    var framesPerBuffer: UInt32 { get set }

    /// Total bytes fed into the decoder so far.
    var totalBytesReceived: Int64 { get }

    // MARK: - Lifecycle

    init()
    /// - Parameter fileTypeHint: An `AudioFileTypeID` hint (0 = unknown).
    func open(fileTypeHint: AudioFileTypeID) throws

    /// Push raw (possibly compressed) audio data into the decoder.
    func feed(_ data: Data)

    /// Flush any internally buffered data (call at end of stream).
    func flush()

    /// Calculate the byte offset for seeking to the given time.
    func seekOffset(for time: TimeInterval) -> Int64?

    /// Reset decoder state for a new segment (e.g., after seek).
    /// This prepares the parser and converter for a discontinuity.
    func resetForSeek()

    /// Release all resources.
    func close()

    /// Recalculate duration after content length becomes available.
    func updateDuration()
}

public protocol VIStreamDecodingWithExtension: VIStreamDecoding {
    var fileExtension: String { get set }
}
