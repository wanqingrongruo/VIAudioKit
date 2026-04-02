import Foundation

/// Abstraction over a byte-level data source. Unifies local files and
/// network-cached resources behind a single random-read interface.
///
/// Decoders read from this protocol without caring whether the data
/// comes from disk or the network.
public protocol VIAudioSource: AnyObject {

    /// Total byte length of the resource. `nil` if unknown.
    var contentLength: Int64? { get }

    /// URL of the source (local file URL or remote URL).
    var url: URL { get }

    /// File extension hint (lowercase, without dot). Used by decoders to pick format.
    var fileExtension: String { get }

    /// Ranges currently available for reading without blocking.
    var availableRanges: [Range<Int64>] { get }

    /// Whether the entire resource is available (local file or fully cached).
    var isFullyAvailable: Bool { get }

    /// Read `length` bytes starting at `offset`.
    /// For network sources this may block until data is downloaded.
    /// - Throws: If the read fails or is cancelled.
    func read(offset: Int64, length: Int) throws -> Data

    /// Release resources.
    func close()
}

/// Errors from audio source operations.
public enum VIAudioSourceError: Error, Sendable {
    case readFailed
    case offsetOutOfRange
    case cancelled
    case downloadTimeout
}
