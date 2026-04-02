import AVFoundation
import AudioToolbox
#if !COCOAPODS
import VIAudioDownloader
#endif

/// Decoder for Apple-natively-supported formats using ExtAudioFile.
/// Supports mp3, aac, m4a, flac, alac, wav, aiff, caf.
///
/// **Local files only.** Network sources use `VIStreamDecoder` (push model).
public final class VINativeDecoder: VIAudioDecoding {

    public static let supportedExtensions: Set<String> = [
        "mp3", "aac", "m4a", "mp4", "flac", "alac", "wav", "aiff", "aif", "caf"
    ]

    public let outputFormat: AVAudioFormat
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0

    private var extAudioFile: ExtAudioFileRef?
    private let source: VIAudioSource
    private let totalFrames: Int64
    private let sampleRate: Double
    private let lock = NSLock()

    // MARK: - Init

    public required init(source: VIAudioSource) throws {
        self.source = source

        guard source.url.isFileURL else {
            throw VIDecoderError.unsupportedFormat("VINativeDecoder only supports local files. Use VIStreamDecoder for network sources.")
        }

        VILogger.debug("[VINativeDecoder] Opening: \(source.url.path)")
        var extFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(source.url as CFURL, &extFile)
        guard openStatus == noErr, extFile != nil else {
            VILogger.debug("[VINativeDecoder] ExtAudioFileOpenURL failed: \(openStatus)")
            throw VIDecoderError.fileOpenFailed(openStatus)
        }
        self.extAudioFile = extFile

        var srcFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = ExtAudioFileGetProperty(extFile!, kExtAudioFileProperty_FileDataFormat, &propSize, &srcFormat)
        guard fmtStatus == noErr else {
            VILogger.debug("[VINativeDecoder] Failed to read source format: \(fmtStatus)")
            ExtAudioFileDispose(extFile!)
            throw VIDecoderError.fileOpenFailed(fmtStatus)
        }

        guard srcFormat.mSampleRate > 0, srcFormat.mChannelsPerFrame > 0 else {
            VILogger.debug("[VINativeDecoder] Invalid source format: rate=\(srcFormat.mSampleRate) ch=\(srcFormat.mChannelsPerFrame)")
            ExtAudioFileDispose(extFile!)
            throw VIDecoderError.unsupportedFormat("Invalid source format")
        }

        self.sampleRate = srcFormat.mSampleRate
        VILogger.debug("[VINativeDecoder] Source: rate=\(sampleRate) ch=\(srcFormat.mChannelsPerFrame) bitsPerCh=\(srcFormat.mBitsPerChannel)")

        let channels = srcFormat.mChannelsPerFrame
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            ExtAudioFileDispose(extFile!)
            throw VIDecoderError.unsupportedFormat("Cannot create output format")
        }
        self.outputFormat = outFmt

        var clientDesc = outFmt.streamDescription.pointee
        let setStatus = ExtAudioFileSetProperty(
            extFile!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientDesc
        )
        guard setStatus == noErr else {
            VILogger.debug("[VINativeDecoder] Failed to set client format: \(setStatus)")
            ExtAudioFileDispose(extFile!)
            throw VIDecoderError.decodeFailed(setStatus)
        }

        var frameCount: Int64 = 0
        var frameCountSize = UInt32(MemoryLayout<Int64>.size)
        let lenStatus = ExtAudioFileGetProperty(extFile!, kExtAudioFileProperty_FileLengthFrames, &frameCountSize, &frameCount)
        if lenStatus != noErr {
            VILogger.debug("[VINativeDecoder] Warning: cannot read total frames: \(lenStatus)")
        }

        self.totalFrames = frameCount
        self.duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0

        VILogger.debug("[VINativeDecoder] Ready: totalFrames=\(totalFrames) duration=\(String(format: "%.2f", duration))s")
    }

    // MARK: - Decode

    private var decodeCallCount = 0

    public func decode(into buffer: AVAudioPCMBuffer) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile = extAudioFile else { throw VIDecoderError.sourceUnavailable }

        buffer.frameLength = buffer.frameCapacity
        let ablPtr = buffer.mutableAudioBufferList

        var frameCount = buffer.frameCapacity
        let status = ExtAudioFileRead(audioFile, &frameCount, ablPtr)
        guard status == noErr else {
            VILogger.debug("[VINativeDecoder] ExtAudioFileRead error: \(status)")
            throw VIDecoderError.decodeFailed(status)
        }

        buffer.frameLength = frameCount
        decodeCallCount += 1

        if decodeCallCount <= 3 || frameCount == 0 {
            VILogger.debug("[VINativeDecoder] decode #\(decodeCallCount): frames=\(frameCount) capacity=\(buffer.frameCapacity)")
        }

        if frameCount == 0 {
            return false
        }

        currentTime = sampleRate > 0 ? Double(currentFramePosition) / sampleRate : 0
        return true
    }

    // MARK: - Seek

    public func seek(to time: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile = extAudioFile else { throw VIDecoderError.sourceUnavailable }

        let targetFrame = Int64(time * sampleRate)
        let clampedFrame = max(0, min(targetFrame, totalFrames))
        let status = ExtAudioFileSeek(audioFile, clampedFrame)
        guard status == noErr else { throw VIDecoderError.seekFailed(status) }
        currentTime = sampleRate > 0 ? Double(clampedFrame) / sampleRate : 0
    }

    // MARK: - Close

    public func close() {
        lock.lock()
        if let extFile = extAudioFile {
            ExtAudioFileDispose(extFile)
            self.extAudioFile = nil
        }
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - Helpers

    private var currentFramePosition: Int64 {
        guard let audioFile = extAudioFile else { return 0 }
        var tellPos: Int64 = 0
        ExtAudioFileTell(audioFile, &tellPos)
        return tellPos
    }
}
