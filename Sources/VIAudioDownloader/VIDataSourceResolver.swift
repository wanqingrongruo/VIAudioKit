import Foundation

/// Describes one piece of a byte-range read plan: either read from a cached file
/// or fetch from the network.
public enum VIResolvedSource {
    /// Read from a cached file segment on disk.
    case file(segment: VICacheSegment, readRange: Range<Int64>)
    /// Fetch from the network with an HTTP Range request.
    case network(range: Range<Int64>)
}

/// Resolves a requested byte range against a `VICacheUnit`'s segments,
/// producing an ordered list of `VIResolvedSource` entries.
/// Cached regions map to `.file`, gaps map to `.network`.
///
/// This is the core "hole-filling" algorithm, analogous to
/// `KTVHCDataReader.prepareSourceManager` in KTVHTTPCache.
public struct VIDataSourceResolver {

    /// Resolve the given byte range against the unit's cached segments.
    ///
    /// - Parameters:
    ///   - range: The requested byte range (half-open, e.g. `0..<1048576`).
    ///   - unit:  The cache unit to check.
    /// - Returns: Ordered array of resolved sources covering the entire `range`.
    public static func resolve(range: Range<Int64>, unit: VICacheUnit) -> [VIResolvedSource] {
        let segments = unit.segments
        guard !segments.isEmpty else {
            return [.network(range: range)]
        }

        // Step 1: Collect file sources from segments that overlap with the requested range.
        var fileSources: [(segment: VICacheSegment, readRange: Range<Int64>)] = []
        var trimmedStart = range.lowerBound

        for seg in segments {
            guard seg.length > 0 else { continue }
            let segEnd = seg.offset + seg.length
            // Skip segments that don't overlap
            guard segEnd > range.lowerBound && seg.offset < range.upperBound else { continue }

            let effectiveStart = max(seg.offset, trimmedStart)
            let effectiveEnd = min(segEnd, range.upperBound)
            guard effectiveStart < effectiveEnd else { continue }

            let readRange = effectiveStart..<effectiveEnd
            fileSources.append((seg, readRange))
            trimmedStart = effectiveEnd
        }

        // Sort by readRange start
        fileSources.sort { $0.readRange.lowerBound < $1.readRange.lowerBound }

        // Step 2: Walk through file sources and fill gaps with network sources.
        var result: [VIResolvedSource] = []
        var cursor = range.lowerBound

        for (seg, readRange) in fileSources {
            // Gap before this file source → network
            if cursor < readRange.lowerBound {
                result.append(.network(range: cursor..<readRange.lowerBound))
            }
            // File source
            result.append(.file(segment: seg, readRange: readRange))
            cursor = readRange.upperBound
        }

        // Trailing gap
        if cursor < range.upperBound {
            result.append(.network(range: cursor..<range.upperBound))
        }

        return result
    }

    /// Convenience: check whether any part of the range needs downloading.
    public static func needsDownload(range: Range<Int64>, unit: VICacheUnit) -> Bool {
        resolve(range: range, unit: unit).contains { source in
            if case .network = source { return true }
            return false
        }
    }
}
