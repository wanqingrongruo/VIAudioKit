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

    private var audioFileID: AudioFileID?

    // MARK: - Init

    public required init(source: VIAudioSource) throws {
        self.source = source

        guard source.url.isFileURL else {
            throw VIDecoderError.unsupportedFormat("VINativeDecoder only supports local files. Use VIStreamDecoder for network sources.")
        }

        VILogger.debug("[VINativeDecoder] Opening: \(source.url.path)")
        var extFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(source.url as CFURL, &extFile)

        if openStatus != noErr || extFile == nil {
            // ExtAudioFileOpenURL 依赖文件扩展名识别格式。
            // 缓存文件使用 hash 命名无扩展名，需通过 AudioFileOpenURL + typeHint 打开。
            // 先读文件头用于诊断
            if let headerData = try? Data(contentsOf: source.url, options: .mappedIfSafe).prefix(16) {
                let hex = headerData.map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = String(data: headerData, encoding: .ascii) ?? ""
                VILogger.debug("[VINativeDecoder] File header (hex): \(hex)")
                VILogger.debug("[VINativeDecoder] File header (ascii): \(ascii.prefix(16))")
            }
            VILogger.debug("[VINativeDecoder] ExtAudioFileOpenURL failed (\(openStatus)), trying AudioFileOpenURL with type hint: \(source.fileExtension)")
            let typeHint = Self.audioFileTypeHint(for: source.fileExtension)

            // 先用明确的 typeHint 尝试，失败后用 0 让系统自动探测格式
            let hints: [AudioFileTypeID] = typeHint != 0 ? [typeHint, 0] : [0]
            var afID: AudioFileID?
            var afStatus: OSStatus = -1

            for hint in hints {
                afStatus = AudioFileOpenURL(source.url as CFURL, .readPermission, hint, &afID)
                if afStatus == noErr && afID != nil {
                    VILogger.debug("[VINativeDecoder] AudioFileOpenURL succeeded with hint=\(hint)")
                    break
                }
                VILogger.debug("[VINativeDecoder] AudioFileOpenURL failed with hint=\(hint): \(afStatus)")
                afID = nil
            }

            guard afStatus == noErr, let afID else {
                VILogger.debug("[VINativeDecoder] All AudioFileOpenURL attempts failed")
                throw VIDecoderError.fileOpenFailed(afStatus)
            }
            self.audioFileID = afID
            let wrapStatus = ExtAudioFileWrapAudioFileID(afID, false, &extFile)
            guard wrapStatus == noErr, extFile != nil else {
                AudioFileClose(afID)
                VILogger.debug("[VINativeDecoder] ExtAudioFileWrapAudioFileID failed: \(wrapStatus)")
                throw VIDecoderError.fileOpenFailed(wrapStatus)
            }
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
        // audioFileID 必须在 ExtAudioFileDispose 之后关闭
        if let afID = audioFileID {
            AudioFileClose(afID)
            self.audioFileID = nil
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

    /// 将文件扩展名映射为 AudioToolbox 的 AudioFileTypeID，
    /// 供 AudioFileOpenURL 在文件缺少扩展名时使用。
    private static func audioFileTypeHint(for ext: String) -> AudioFileTypeID {
        switch ext.lowercased() {
        case "wav":  return kAudioFileWAVEType
        case "mp3":  return kAudioFileMP3Type
        case "aac":  return kAudioFileAAC_ADTSType
        case "m4a":  return kAudioFileM4AType
        case "mp4":  return kAudioFileMPEG4Type
        case "flac": return kAudioFileFLACType
        case "aiff", "aif": return kAudioFileAIFFType
        case "caf":  return kAudioFileCAFType
        default:     return 0
        }
    }
}
