import Foundation

/// Thread-safe manager for all cache units. Handles persistence (JSON), LRU eviction,
/// and cache queries. Analogous to KTVHTTPCache's `KTVHCDataUnitPool`.
public final class VICacheManager: @unchecked Sendable {

    public let configuration: VIDownloaderConfiguration

    private var units: [String: VICacheUnit] = [:]
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    private var saveWorkItem: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.viaudiokit.cache.io", qos: .utility)

    private var indexFileURL: URL {
        configuration.cacheDirectory.appendingPathComponent("index.json")
    }

    // MARK: - Init

    public init(configuration: VIDownloaderConfiguration) {
        self.configuration = configuration
        ensureDirectoryExists(configuration.cacheDirectory)
        loadIndex()
    }

    // MARK: - Unit access

    /// Retrieve or create a cache unit for the given URL.
    public func unit(for url: URL) -> VICacheUnit {
        let key = configuration.cacheKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        if let existing = units[key] {
            existing.lastAccessTime = Date()
            return existing
        }
        let unit = VICacheUnit(key: key, originalURL: url)
        units[key] = unit
        ensureDirectoryExists(directoryForUnit(key))
        scheduleSave()
        return unit
    }

    /// Retrieve a cache unit by key without creating one.
    public func existingUnit(forKey key: String) -> VICacheUnit? {
        lock.lock()
        defer { lock.unlock() }
        return units[key]
    }

    /// Retrieve a cache unit by URL without creating one.
    public func existingUnit(for url: URL) -> VICacheUnit? {
        let key = configuration.cacheKey(for: url)
        return existingUnit(forKey: key)
    }

    // MARK: - Cache status

    /// Status of the cache for a given URL.
    public func cacheStatus(for url: URL) -> VICacheStatus {
        guard let unit = existingUnit(for: url) else { return .none }
        if unit.isComplete, let rp = unit.completeSegmentRelativePath {
            let filePath = directoryForUnit(unit.key).appendingPathComponent(rp)
            return .complete(fileURL: filePath)
        }
        guard let total = unit.totalLength else { return .none }
        return .partial(downloaded: unit.validLength, total: total, ranges: unit.cachedRanges)
    }

    /// Absolute file URL if the resource is completely cached.
    public func completeCacheURL(for url: URL) -> URL? {
        guard let unit = existingUnit(for: url) else {
            return nil
        }
        guard let rp = unit.completeSegmentRelativePath else {
            return nil
        }
        return directoryForUnit(unit.key).appendingPathComponent(rp)
    }

    // MARK: - File paths

    /// Directory on disk for a given cache key.
    public func directoryForUnit(_ key: String) -> URL {
        configuration.cacheDirectory.appendingPathComponent(key, isDirectory: true)
    }

    /// Generate a unique file path for a new segment.
    public func segmentFilePath(unitKey: String, offset: Int64) -> (relativePath: String, absoluteURL: URL) {
        let dir = directoryForUnit(unitKey)
        ensureDirectoryExists(dir)
        var name = "\(unitKey)_\(offset)"
        var counter = 0
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            counter += 1
            name = "\(unitKey)_\(offset)_\(counter)"
        }
        fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        return (name, dir.appendingPathComponent(name))
    }

    /// Absolute URL for a segment's relative path within its unit's directory.
    public func absoluteURL(forSegment relativePath: String, unitKey: String) -> URL {
        directoryForUnit(unitKey).appendingPathComponent(relativePath)
    }

    // MARK: - Delete

    /// Remove cache for a specific URL.
    public func removeCache(for url: URL) {
        let key = configuration.cacheKey(for: url)
        lock.lock()
        units.removeValue(forKey: key)
        lock.unlock()
        let dir = directoryForUnit(key)
        try? fm.removeItem(at: dir)
        scheduleSave()
    }

    /// Remove all cached data.
    public func removeAllCache() {
        lock.lock()
        units.removeAll()
        lock.unlock()
        try? fm.removeItem(at: configuration.cacheDirectory)
        ensureDirectoryExists(configuration.cacheDirectory)
        scheduleSave()
    }

    // MARK: - LRU Eviction

    /// Evict oldest-accessed units until total size is within `maxCacheSize`.
    public func evictIfNeeded() {
        lock.lock()
        let sorted = units.values.sorted { $0.lastAccessTime < $1.lastAccessTime }
        var totalSize = sorted.reduce(Int64(0)) { $0 + $1.cacheLength }
        var toRemove: [String] = []
        for unit in sorted {
            guard totalSize > configuration.maxCacheSize else { break }
            guard unit.isIdle else { continue }
            totalSize -= unit.cacheLength
            toRemove.append(unit.key)
        }
        for key in toRemove {
            units.removeValue(forKey: key)
        }
        lock.unlock()
        for key in toRemove {
            try? fm.removeItem(at: directoryForUnit(key))
        }
        if !toRemove.isEmpty { scheduleSave() }
    }

    /// Total bytes used by all cache units.
    public var totalCacheLength: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return units.values.reduce(0) { $0 + $1.cacheLength }
    }

    // MARK: - Persistence

    /// Debounced save to prevent excessive I/O.
    public func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveIndex()
        }
        saveWorkItem = item
        ioQueue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// Force an immediate save (call on app termination).
    public func saveImmediately() {
        saveWorkItem?.cancel()
        saveIndex()
    }

    private func saveIndex() {
        lock.lock()
        let snapshot = Array(units.values)
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: indexFileURL, options: .atomic)
        } catch {
            VILogger.debug("[VICacheManager] Failed to save index: \(error)")
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFileURL),
              let loaded = try? JSONDecoder().decode([VICacheUnit].self, from: data) else { return }
        lock.lock()
        for unit in loaded {
            // Re-validate segment file lengths from disk
            let dir = directoryForUnit(unit.key)
            var validSegments: [VICacheSegment] = []
            for var seg in unit.segments {
                let path = dir.appendingPathComponent(seg.relativePath)
                if let attrs = try? fm.attributesOfItem(atPath: path.path),
                   let size = attrs[.size] as? Int64, size > 0 {
                    seg.length = size
                    validSegments.append(seg)
                }
            }
            if !validSegments.isEmpty || unit.totalLength != nil {
                unit.replaceSegments(validSegments)
                units[unit.key] = unit
            }
        }
        lock.unlock()
    }

    // MARK: - Helpers

    private func ensureDirectoryExists(_ url: URL) {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Cache status enum

public enum VICacheStatus: Sendable {
    case none
    case partial(downloaded: Int64, total: Int64, ranges: [Range<Int64>])
    case complete(fileURL: URL)
}
