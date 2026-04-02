import Foundation

/// Audio source backed by a local file. Supports random-access reads via FileHandle.
public final class VILocalFileSource: VIAudioSource {

    public let url: URL
    public let fileExtension: String

    private var fileHandle: FileHandle?
    private let lock = NSLock()
    private let fileSize: Int64

    public init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VIAudioSourceError.readFailed
        }
        self.url = fileURL
        self.fileExtension = fileURL.pathExtension.lowercased()
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.fileSize = (attrs[.size] as? Int64) ?? 0
        self.fileHandle = try FileHandle(forReadingFrom: fileURL)
    }

    // MARK: - VIAudioSource

    public var contentLength: Int64? { fileSize }

    public var availableRanges: [Range<Int64>] {
        [0..<fileSize]
    }

    public var isFullyAvailable: Bool { true }

    public func read(offset: Int64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = fileHandle else { throw VIAudioSourceError.readFailed }
        guard offset >= 0, offset < fileSize else { throw VIAudioSourceError.offsetOutOfRange }
        try handle.seek(toOffset: UInt64(offset))
        let bytesToRead = min(length, Int(fileSize - offset))
        let data = handle.readData(ofLength: bytesToRead)
        guard !data.isEmpty else { throw VIAudioSourceError.readFailed }
        return data
    }

    public func close() {
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
    }

    deinit {
        close()
    }
}
