import Foundation

/// A contiguous byte range that has been cached to disk.
/// Analogous to KTVHTTPCache's `KTVHCDataUnitItem`.
public struct VICacheSegment: Codable, Sendable {

    /// Relative path of the segment file within the cache unit's directory.
    public let relativePath: String

    /// Byte offset of this segment within the full resource.
    public let offset: Int64

    /// Number of bytes written so far. Grows as the download progresses.
    public internal(set) var length: Int64

    /// When the segment was created.
    public let createTime: Date

    public init(relativePath: String, offset: Int64, length: Int64 = 0) {
        self.relativePath = relativePath
        self.offset = offset
        self.length = length
        self.createTime = Date()
    }

    /// The exclusive upper-bound byte position (offset + length).
    public var end: Int64 { offset + length }

    /// Whether this segment contains the byte at `position`.
    public func contains(_ position: Int64) -> Bool {
        position >= offset && position < end
    }

    /// The overlap between this segment and a given range, or nil if disjoint.
    public func overlap(with range: Range<Int64>) -> Range<Int64>? {
        let lo = max(offset, range.lowerBound)
        let hi = min(end, range.upperBound)
        guard lo < hi else { return nil }
        return lo..<hi
    }
}
