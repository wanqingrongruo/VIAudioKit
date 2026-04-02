import AVFoundation
import AudioToolbox
#if !COCOAPODS
import VIAudioDownloader
#endif

/// Push-based decoder for network audio streaming.
///
/// Uses `AudioFileStream` to parse incoming data incrementally and
/// `AudioConverter` to convert compressed audio packets to PCM.
/// Data is pushed in via `feed(_:)` — no blocking reads required.
///
/// This is fundamentally different from `VINativeDecoder` (pull-based).
/// The push model naturally handles network buffering: if no data arrives,
/// nothing happens; when data arrives, it's processed immediately.
public final class VIStreamDecoder: VIStreamDecoding {

    // MARK: - Output callbacks

    /// Called when the audio format and duration are determined from the stream header.
    public var onOutputFormatReady: ((_ format: AVAudioFormat, _ duration: TimeInterval) -> Void)?

    /// Called each time a decoded PCM buffer is ready for playback.
    public var onBufferReady: ((_ buffer: AVAudioPCMBuffer) -> Void)?

    /// Called when the end of the audio stream is reached.
    public var onEndOfStream: (() -> Void)?

    /// Called when a non-recoverable decode error occurs.
    public var onError: ((_ error: Error) -> Void)?

    // MARK: - Public properties

    public private(set) var outputFormat: AVAudioFormat?
    public private(set) var duration: TimeInterval = 0
    public private(set) var dataOffset: Int64 = 0
    public private(set) var bitRate: Double = 0
    public private(set) var sampleRate: Double = 0
    public private(set) var totalDataBytes: Int64 = 0
    public private(set) var totalPacketCount: Double = 0
    public private(set) var packetDuration: Double = 0
    public private(set) var isFormatReady = false

    /// Total content length of the resource (set by player/source).
    public var contentLength: Int64 = 0

    /// The number of PCM frames per output buffer.
    public var framesPerBuffer: UInt32 = 8192

    // MARK: - Internal state

    private var audioFileStream: AudioFileStreamID?
    private var audioConverter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private var discontinuous = false
    private var formatNotified = false
    private var processedPacketCount: Int = 0
    private var processedPacketSizeTotal: UInt32 = 0

    private let lock = NSLock()

    public static let supportedExtensions: Set<String> = [
        "mp3", "aac", "m4a", "mp4", "flac", "wav", "aiff", "aif", "caf"
    ]

    // MARK: - Init

    required public init() {}

    // MARK: - Open / Close

    /// Open an AudioFileStream parser for the given format hint.
    public func open(fileTypeHint: AudioFileTypeID) throws {
        close()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(
            selfPtr,
            streamPropertyListenerProc,
            streamPacketsProc,
            fileTypeHint,
            &audioFileStream
        )
        guard status == noErr else {
            throw VIDecoderError.fileOpenFailed(status)
        }
    }

    public private(set) var totalBytesReceived: Int64 = 0
    private var totalBuffersProduced: Int = 0
    private var packetsCallbackCount: Int = 0

    /// Push raw audio data into the parser. Non-blocking.
    public func feed(_ data: Data) {
        guard let stream = audioFileStream, !data.isEmpty else { return }
        totalBytesReceived += Int64(data.count)
        
        lock.lock()
        let flags: AudioFileStreamParseFlags = discontinuous ? .discontinuity : []
        if discontinuous { discontinuous = false }
        lock.unlock()
        
        data.withUnsafeBytes { raw in
            let status = AudioFileStreamParseBytes(
                stream,
                UInt32(raw.count),
                raw.baseAddress,
                flags
            )
            if status != noErr {
                VILogger.debug("[VIStreamDecoder] AudioFileStreamParseBytes error: \(status)")
            }
        }
    }

    /// Flush remaining packets from the parser (call at end of stream).
    public func flush() {
        guard let stream = audioFileStream else { return }
        AudioFileStreamParseBytes(stream, 0, nil, [])
    }

    /// Calculate the byte offset for a seek to the given time.
    public func seekOffset(for time: TimeInterval) -> Int64? {
        guard duration > 0 else { return nil }

        if let stream = audioFileStream, packetDuration > 0, bitRate > 0 {
            var ioFlags = AudioFileStreamSeekFlags(rawValue: 0)
            var packetOffset: Int64 = 0
            let seekPacket = Int64(floor(time / packetDuration))
            let status = AudioFileStreamSeek(stream, seekPacket, &packetOffset, &ioFlags)
            if status == noErr, !ioFlags.contains(.offsetIsEstimated) {
                return packetOffset + dataOffset
            }
        }

        let ratio = time / duration
        let dataLength = totalDataBytes > 0 ? totalDataBytes : (contentLength - dataOffset)
        return Int64(Double(dataLength) * ratio) + dataOffset
    }

    /// Reset the decoder state for a seek operation.
    /// This prepares the parser and converter for a discontinuity.
    public func resetForSeek() {
        lock.lock()
        discontinuous = true
        if let converter = audioConverter {
            AudioConverterReset(converter)
        }
        lock.unlock()
    }

    /// Release all AudioToolbox resources.
    public func close() {
        lock.lock()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        if let stream = audioFileStream {
            AudioFileStreamClose(stream)
            audioFileStream = nil
        }
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - AudioFileStream property callback

    fileprivate func handleProperty(
        _ stream: AudioFileStreamID,
        _ propertyID: AudioFileStreamPropertyID
    ) {
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            handleDataFormat(stream)

        case kAudioFileStreamProperty_DataOffset:
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataOffset, &size, &offset)
            dataOffset = offset

        case kAudioFileStreamProperty_AudioDataByteCount:
            var byteCount: UInt64 = 0
            var size = UInt32(MemoryLayout<UInt64>.size)
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_AudioDataByteCount, &size, &byteCount)
            totalDataBytes = Int64(byteCount)

        case kAudioFileStreamProperty_AudioDataPacketCount:
            var packetCount: UInt64 = 0
            var size = UInt32(MemoryLayout<UInt64>.size)
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_AudioDataPacketCount, &size, &packetCount)
            totalPacketCount = Double(packetCount)

        case kAudioFileStreamProperty_BitRate:
            var br: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_BitRate, &size, &br)
            if status == noErr {
                bitRate = Double(br)
                VILogger.debug("[VIStreamDecoder] BitRate: \(br)")
                // Recompute duration now that we have bitrate
                computeDuration()
            }

        case kAudioFileStreamProperty_ReadyToProducePackets:
            VILogger.debug("[VIStreamDecoder] ReadyToProducePackets: converter=\(audioConverter != nil) inputFmt=\(inputFormat.mFormatID) dataOffset=\(dataOffset) contentLength=\(contentLength)")
            assignMagicCookie(stream)
            notifyFormatIfNeeded()
            let formatID = inputFormat.mFormatID
            if formatID != kAudioFormatLinearPCM && formatID != kAudioFormatFLAC {
                discontinuous = true
            }

        case kAudioFileStreamProperty_FormatList:
            handleFormatList(stream)

        default:
            break
        }
    }

    private func handleDataFormat(_ stream: AudioFileStreamID) {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(
            stream, kAudioFileStreamProperty_DataFormat, &size, &format
        )
        guard status == noErr else {
            VILogger.debug("[VIStreamDecoder] handleDataFormat: getProperty failed: \(status)")
            return
        }

        VILogger.debug("[VIStreamDecoder] handleDataFormat: formatID=\(format.mFormatID) rate=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) framesPerPkt=\(format.mFramesPerPacket)")

        if inputFormat.mFormatID == 0 {
            inputFormat = format
        }
        sampleRate = format.mSampleRate
        if format.mFramesPerPacket > 0, sampleRate > 0 {
            packetDuration = Double(format.mFramesPerPacket) / sampleRate
        }

        createConverter(from: format)
    }

    private func handleFormatList(_ stream: AudioFileStreamID) {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioFileStreamGetPropertyInfo(
            stream, kAudioFileStreamProperty_FormatList, &size, &writable
        ) == noErr, size > 0 else { return }

        let count = Int(size) / MemoryLayout<AudioFormatListItem>.stride
        guard count > 0 else { return }

        var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
        AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &size, &list)

        for item in list where item.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE
            || item.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
            inputFormat = item.mASBD
            sampleRate = item.mASBD.mSampleRate
            if item.mASBD.mFramesPerPacket > 0, sampleRate > 0 {
                packetDuration = Double(item.mASBD.mFramesPerPacket) / sampleRate
            }
            createConverter(from: item.mASBD)
            return
        }
    }

    // MARK: - AudioConverter

    private func createConverter(from sourceFormat: AudioStreamBasicDescription) {
        VILogger.debug("[VIStreamDecoder] createConverter: in=\(sourceFormat.mFormatID) rate=\(sourceFormat.mSampleRate) ch=\(sourceFormat.mChannelsPerFrame) bitsPerCh=\(sourceFormat.mBitsPerChannel) framesPerPkt=\(sourceFormat.mFramesPerPacket)")
        var inFmt = sourceFormat
        if let existing = audioConverter {
            if memcmp(&inFmt, &inputFormat, MemoryLayout<AudioStreamBasicDescription>.size) == 0 {
                AudioConverterReset(existing)
                VILogger.debug("[VIStreamDecoder] createConverter: reset existing")
                return
            }
            AudioConverterDispose(existing)
            audioConverter = nil
        }

        // Non-interleaved: each buffer holds a single channel,
        // so mBytesPerFrame/mBytesPerPacket = sizeof(Float32) = 4, NOT multiplied by channels.
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: sourceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        var classDesc = AudioClassDescription()
        if getHardwareCodecClass(formatID: sourceFormat.mFormatID, classDesc: &classDesc) {
            AudioConverterNewSpecific(&inFmt, &outFmt, 1, &classDesc, &converter)
        }
        if converter == nil {
            let status = AudioConverterNew(&inFmt, &outFmt, &converter)
            if status != noErr {
                VILogger.debug("[VIStreamDecoder] AudioConverterNew failed: \(status)")
                onError?(VIDecoderError.decodeFailed(status))
                return
            }
        }
        audioConverter = converter
        inputFormat = inFmt
        assignMagicCookie(audioFileStream)
    }

    private func assignMagicCookie(_ stream: AudioFileStreamID?) {
        guard let stream = stream, let converter = audioConverter else { return }
        var cookieSize: UInt32 = 0
        guard AudioFileStreamGetPropertyInfo(
            stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil
        ) == noErr, cookieSize > 0 else { return }
        var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
        guard AudioFileStreamGetProperty(
            stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie
        ) == noErr else { return }
        AudioConverterSetProperty(
            converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie
        )
    }

    private func getHardwareCodecClass(
        formatID: UInt32,
        classDesc: UnsafeMutablePointer<AudioClassDescription>
    ) -> Bool {
        #if os(iOS) || os(tvOS)
        var size: UInt32 = 0
        var id = formatID
        let idSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetPropertyInfo(
            kAudioFormatProperty_Decoders, idSize, &id, &size
        ) == noErr else { return false }
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        var descriptions = [AudioClassDescription](repeating: AudioClassDescription(), count: count)
        guard AudioFormatGetProperty(
            kAudioFormatProperty_Decoders, idSize, &id, &size, &descriptions
        ) == noErr else { return false }
        for desc in descriptions where desc.mManufacturer == kAppleHardwareAudioCodecManufacturer {
            classDesc.pointee = desc
            return true
        }
        #endif
        return false
    }

    // MARK: - Packets callback

    fileprivate func handlePackets(
        _ numBytes: UInt32,
        _ numPackets: UInt32,
        _ data: UnsafeRawPointer,
        _ packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        packetsCallbackCount += 1
        if packetsCallbackCount <= 3 {
            VILogger.debug("[VIStreamDecoder] handlePackets #\(packetsCallbackCount): bytes=\(numBytes) packets=\(numPackets) formatReady=\(isFormatReady) converter=\(audioConverter != nil) outputFmt=\(outputFormat != nil)")
        }

        guard isFormatReady || outputFormat != nil else {
            VILogger.debug("[VIStreamDecoder] handlePackets: skipped (format not ready)")
            return
        }
        guard let converter = audioConverter else {
            VILogger.debug("[VIStreamDecoder] handlePackets: skipped (no converter)")
            return
        }

        notifyFormatIfNeeded()

        discontinuous = false

        updateProcessedPackets(numPackets: numPackets, descs: packetDescs)
        // For formats where BitRate property is delayed/absent (common with MP3),
        // continuously refine duration using calculated bitrate from parsed packets.
        // VIAudioPlayer lazily reads `sd.duration` during time updates.
        computeDuration()

        var convertInfo = ConvertInfo(
            done: false,
            numPackets: numPackets,
            data: data,
            dataSize: numBytes,
            packetDescs: packetDescs
        )

        guard let outFmt = outputFormat else { return }

        while true {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outFmt,
                frameCapacity: framesPerBuffer
            ) else { break }

            buffer.frameLength = framesPerBuffer

            var outputDataPacketSize = framesPerBuffer
            let ablPtr = buffer.mutableAudioBufferList

            let status = AudioConverterFillComplexBuffer(
                converter,
                converterInputCallback,
                &convertInfo,
                &outputDataPacketSize,
                ablPtr,
                nil
            )

            buffer.frameLength = outputDataPacketSize

            if outputDataPacketSize > 0 {
                totalBuffersProduced += 1
                if totalBuffersProduced <= 5 {
                    VILogger.debug("[VIStreamDecoder] buffer #\(totalBuffersProduced): frames=\(outputDataPacketSize)")
                }
                onBufferReady?(buffer)
            }

            if status == 100 { break }
            if status != noErr && status != 100 {
                VILogger.debug("[VIStreamDecoder] AudioConverterFillComplexBuffer error: \(status)")
                break
            }
        }
    }

    private func updateProcessedPackets(
        numPackets: UInt32,
        descs: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard let descs = descs else { return }
        let maxTracked = 4096
        let count = min(Int(numPackets), maxTracked - processedPacketCount)
        for i in 0..<count {
            processedPacketSizeTotal += descs[i].mDataByteSize
            processedPacketCount += 1
        }
    }

    // MARK: - Format notification

    private func notifyFormatIfNeeded() {
        guard !formatNotified, sampleRate > 0, inputFormat.mChannelsPerFrame > 0 else { return }
        guard audioConverter != nil else { return }

        let channels = inputFormat.mChannelsPerFrame
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { return }

        outputFormat = fmt
        isFormatReady = true
        computeDuration()
        formatNotified = true

        VILogger.debug("[VIStreamDecoder] Format ready: rate=\(sampleRate) ch=\(channels) duration=\(String(format: "%.2f", duration))s")
        onOutputFormatReady?(fmt, duration)
    }

    private func computeDuration() {
        let oldDur = duration
        if totalPacketCount > 0, packetDuration > 0 {
            duration = totalPacketCount * packetDuration
        } else if contentLength > 0 {
            let br = bitRate > 0 ? bitRate : calculatedBitrate()
            guard br > 0 else { return }
            let dataBytes = totalDataBytes > 0 ? totalDataBytes : (contentLength - dataOffset)
            duration = Double(dataBytes) * 8.0 / br
        }
        if duration != oldDur || duration == 0 {
            VILogger.debug("[VIStreamDecoder] computeDuration: packets=\(totalPacketCount) packetDur=\(packetDuration) bitRate=\(bitRate) contentLength=\(contentLength) dataOffset=\(dataOffset) totalDataBytes=\(totalDataBytes) → duration=\(String(format: "%.2f", duration))s")
        }
    }

    /// Recalculate duration with updated info (call after contentLength is known).
    public func updateDuration() {
        computeDuration()
        if duration > 0, formatNotified {
            VILogger.debug("[VIStreamDecoder] updateDuration: \(String(format: "%.2f", duration))s (post-format)")
        }
    }

    // MARK: - Calculated bitrate

    public func calculatedBitrate() -> Double {
        if bitRate > 0 { return bitRate }
        guard processedPacketCount > 0, packetDuration > 0 else { return 0 }
        let avgPacketSize = Double(processedPacketSizeTotal) / Double(processedPacketCount)
        return avgPacketSize * 8.0 / packetDuration
    }
}

// MARK: - C Callbacks

private func streamPropertyListenerProc(
    clientData: UnsafeMutableRawPointer,
    stream: AudioFileStreamID,
    propertyID: AudioFileStreamPropertyID,
    flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let decoder = Unmanaged<VIStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
    decoder.handleProperty(stream, propertyID)
}

private func streamPacketsProc(
    clientData: UnsafeMutableRawPointer,
    numBytes: UInt32,
    numPackets: UInt32,
    data: UnsafeRawPointer,
    packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let decoder = Unmanaged<VIStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
    decoder.handlePackets(numBytes, numPackets, data, packetDescs)
}

// MARK: - AudioConverter input callback

private struct ConvertInfo {
    var done: Bool
    let numPackets: UInt32
    let data: UnsafeRawPointer
    let dataSize: UInt32
    let packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription>?
}

private func converterInputCallback(
    _: AudioConverterRef,
    ioNumDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDescs: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let info = userData?.assumingMemoryBound(to: ConvertInfo.self) else { return 0 }
    if info.pointee.done {
        ioNumDataPackets.pointee = 0
        return 100 // done sentinel
    }

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: info.pointee.data)
    ioData.pointee.mBuffers.mDataByteSize = info.pointee.dataSize
    ioData.pointee.mBuffers.mNumberChannels = 0

    outDescs?.pointee = info.pointee.packetDescs
    ioNumDataPackets.pointee = info.pointee.numPackets
    info.pointee.done = true

    return noErr
}

// MARK: - File type hint helper

extension VIStreamDecoder {
    public static func fileTypeHint(for ext: String) -> AudioFileTypeID {
        switch ext.lowercased() {
        case "mp3":          return kAudioFileMP3Type
        case "aac":          return kAudioFileAAC_ADTSType
        case "m4a":          return kAudioFileM4AType
        case "mp4":          return kAudioFileMPEG4Type
        case "flac":         return kAudioFileFLACType
        case "wav":          return kAudioFileWAVEType
        case "aiff", "aif":  return kAudioFileAIFFType
        case "caf":          return kAudioFileCAFType
        default:             return 0
        }
    }
}
