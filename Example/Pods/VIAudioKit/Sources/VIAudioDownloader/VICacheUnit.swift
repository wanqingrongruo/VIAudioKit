import Foundation

/// Represents one cached audio resource, consisting of zero or more byte-range
/// segments on disk. Analogous to KTVHTTPCache's `KTVHCDataUnit`.
public final class VICacheUnit: Codable, @unchecked Sendable {

    /// SHA-256 key derived from the canonicalized URL.
    public let key: String

    /// The original URL used when this unit was first created.
    public let originalURL: URL

    /// Total content length from `Content-Length` / `Content-Range`.
    /// `nil` until the first server response arrives.
    public var totalLength: Int64?

    /// Filtered response headers (Content-Type, Accept-Ranges, etc.)
    public var responseHeaders: [String: String]?

    /// Cached byte segments, kept sorted by `offset` ascending.
    public private(set) var segments: [VICacheSegment]

    /// When this unit was first created.
    public let createTime: Date

    /// When this unit was last read or written.
    public internal(set) var lastAccessTime: Date

    /// Number of active readers / writers. Merge only happens when this reaches 0.
    private var workingCount: Int = 0

    private let lock = NSRecursiveLock()

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case key, originalURL, totalLength, responseHeaders, segments, createTime, lastAccessTime
    }

    // MARK: - Init

    public init(key: String, originalURL: URL) {
        self.key = key
        self.originalURL = originalURL
        self.totalLength = nil
        self.responseHeaders = nil
        self.segments = []
        self.createTime = Date()
        self.lastAccessTime = Date()
    }

    // MARK: - Segment management

    /// Insert a new segment and re-sort. Thread-safe.
    public func insertSegment(_ segment: VICacheSegment) {
        lock.lock()
        segments.append(segment)
        sortSegments()
        lock.unlock()
    }

    /// Update the length of a segment at the given index. Thread-safe.
    public func updateSegmentLength(at index: Int, length: Int64) {
        lock.lock()
        guard index < segments.count else { lock.unlock(); return }
        segments[index].length = length
        lock.unlock()
    }

    /// Find the index of the segment whose `relativePath` matches.
    public func segmentIndex(for relativePath: String) -> Int? {
        lock.lock()
        let idx = segments.firstIndex(where: { $0.relativePath == relativePath })
        lock.unlock()
        return idx
    }

    // MARK: - Computed cache metrics

    /// Union of all cached byte ranges, deduplicating overlaps.
    /// Analogous to KTVHTTPCache's `validLength`.
    public var validLength: Int64 {
        lock.lock()
        defer { lock.unlock() }
        var cursor: Int64 = 0
        var total: Int64 = 0
        for seg in segments {
            let invalid = max(cursor - seg.offset, 0)
            let valid = max(seg.length - invalid, 0)
            cursor = max(cursor, seg.offset + seg.length)
            total += valid
        }
        return total
    }

    /// Total raw bytes on disk (may exceed `validLength` if segments overlap).
    public var cacheLength: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.length }
    }

    /// Whether the entire resource has been cached.
    public var isComplete: Bool {
        guard let total = totalLength, total > 0 else { return false }
        return validLength >= total
    }

    /// If the cache consists of a single segment covering the full resource, return
    /// its relative path. Used after merging.
    public var completeSegmentRelativePath: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let total = totalLength,
              segments.count == 1,
              segments[0].offset == 0,
              segments[0].length >= total else { return nil }
        return segments[0].relativePath
    }

    /// Returns cached ranges as a sorted array of `Range<Int64>`.
    public var cachedRanges: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Range<Int64>] = []
        for seg in segments where seg.length > 0 {
            let range = seg.offset..<seg.end
            if let last = result.last, last.upperBound >= range.lowerBound {
                let merged = last.lowerBound..<max(last.upperBound, range.upperBound)
                result[result.count - 1] = merged
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Check whether a specific byte range is fully cached.
    public func isCached(range: Range<Int64>) -> Bool {
        let cached = cachedRanges
        for cr in cached {
            if cr.lowerBound <= range.lowerBound && cr.upperBound >= range.upperBound {
                return true
            }
        }
        return false
    }

    // MARK: - Working count (reader/writer tracking)

    public func retainWorking() {
        lock.lock()
        workingCount += 1
        lock.unlock()
    }

    public func releaseWorking() {
        lock.lock()
        workingCount -= 1
        lock.unlock()
    }

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return workingCount <= 0
    }

    // MARK: - Merge

    /// Merge all segment files into a single file when complete and idle.
    /// Returns the relative path of the merged file, or nil if not applicable.
    @discardableResult
    public func mergeIfNeeded(in directory: URL) -> String? {
        lock.lock()
        guard workingCount <= 0,
              let total = totalLength, total > 0,
              validLength >= total,
              segments.count > 1 else {
            lock.unlock()
            return nil
        }
        let segs = segments
        lock.unlock()

        let mergedName = "\(key).complete"
        let mergedPath = directory.appendingPathComponent(mergedName)

        let fm = FileManager.default
        try? fm.removeItem(at: mergedPath)
        fm.createFile(atPath: mergedPath.path, contents: nil)

        guard let writeHandle = try? FileHandle(forWritingTo: mergedPath) else { return nil }
        defer { try? writeHandle.close() }

        var cursor: Int64 = 0
        for seg in segs {
            guard cursor < seg.offset + seg.length else { continue }
            let filePath = directory.appendingPathComponent(seg.relativePath)
            guard let readHandle = try? FileHandle(forReadingFrom: filePath) else { return nil }
            defer { try? readHandle.close() }

            let skipBytes = max(cursor - seg.offset, 0)
            if skipBytes > 0 {
                try? readHandle.seek(toOffset: UInt64(skipBytes))
            }

            while true {
                autoreleasepool {
                    let chunk = readHandle.readData(ofLength: 1024 * 1024)
                    if chunk.isEmpty { return }
                    writeHandle.write(chunk)
                }
                let pos = try? readHandle.offset()
                if pos == nil { break }
                if (try? readHandle.offset()) == UInt64(seg.length) { break }
            }
            cursor = seg.offset + seg.length
        }

        let fileSize = (try? fm.attributesOfItem(atPath: mergedPath.path)[.size] as? Int64) ?? 0
        guard fileSize == total else {
            try? fm.removeItem(at: mergedPath)
            return nil
        }

        // Replace segments with the single merged segment
        lock.lock()
        for seg in segments {
            let path = directory.appendingPathComponent(seg.relativePath)
            try? fm.removeItem(at: path)
        }
        segments = [VICacheSegment(relativePath: mergedName, offset: 0, length: total)]
        lock.unlock()

        return mergedName
    }

    // MARK: - Internal

    /// Replace all segments with the given list. Used during index reload
    /// to discard segments whose backing files no longer exist on disk.
    internal func replaceSegments(_ newSegments: [VICacheSegment]) {
        lock.lock()
        segments = newSegments
        sortSegments()
        lock.unlock()
    }

    // MARK: - Private

    private func sortSegments() {
        segments.sort { a, b in
            if a.offset != b.offset { return a.offset < b.offset }
            return a.length > b.length
        }
    }
}
