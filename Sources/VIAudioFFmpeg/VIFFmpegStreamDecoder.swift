import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDecoder
#endif

#if canImport(CFFmpeg)
import CFFmpeg
#endif

/// Decoder implementation using FFmpeg C API for streaming (push model).
/// Supports OGG, WMA, APE, FLAC, M4A, etc.
public final class VIFFmpegStreamDecoder: VIStreamDecodingWithExtension {
    
    public static let supportedExtensions: Set<String> = [
        "ogg", "oga", "opus", "wma", "ape", "wv"
    ]
    public var onError: ((Error) -> Void)?
    public var onOutputFormatReady: ((AVAudioFormat, TimeInterval) -> Void)?
    public var onBufferReady: ((AVAudioPCMBuffer) -> Void)?
    public var onEndOfStream: (() -> Void)?
    
    private var _outputFormat: AVAudioFormat?
    public var outputFormat: AVAudioFormat? { return _outputFormat }
    
    public private(set) var duration: TimeInterval = 0
    public var contentLength: Int64 = 0
    public var framesPerBuffer: UInt32 = 8192
    public private(set) var totalBytesReceived: Int64 = 0
    
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var avioContext: UnsafeMutablePointer<AVIOContext>?
    private var streamIndex: Int32 = -1
    private var ioBuffer: UnsafeMutablePointer<UInt8>?
    private let ioBufferSize = 32768
    
    private var resampler = FFmpegResampler()
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    
    // Ring buffer for push data
    private var ringBuffer: Data
    private var ringHead: Int = 0
    private var ringTail: Int = 0
    private var isRingClosed: Bool = false
    private var isAborted: Bool = false
    private var isSeeking: Bool = false
    private let ringCapacity = 10 * 1024 * 1024 // 10MB ring buffer
    
    private let stateLock = NSRecursiveLock()
    private let ringCondition = NSCondition()
    
    private var decoderThread: Thread?
    private var _isFormatReady = false
    public var fileExtension: String = ""
    /// 仅用于诊断：限制 readData 日志条数，避免探测阶段刷屏
    private var readDataLogSerial: Int = 0
    
    required public init() {
        ringBuffer = Data(count: ringCapacity)
        avformat_network_init()
    }
    
    public func open(fileTypeHint: AudioFileTypeID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        isRingClosed = false
        isAborted = false
        isSeeking = false
        ringHead = 0
        ringTail = 0
        
        ioBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ioBufferSize)
        
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        avioContext = avio_alloc_context(
            ioBuffer,
            Int32(ioBufferSize),
            0,
            opaque,
            streamReadPacketCallback,
            nil,
            nil
        )
        
        if avioContext == nil {
            throw VIDecoderError.fileOpenFailed(-1)
        }
        
        formatContext = avformat_alloc_context()
        formatContext?.pointee.pb = avioContext
        
        // Start decode thread
        decoderThread = Thread { [weak self] in
            self?.decodeLoop()
        }
        decoderThread?.name = "com.viaudiokit.ffmpeg.stream"
        decoderThread?.start()
        VILogger.debug("[VIA_FFMPEG_PUSH] open() OK, decode thread started (ext=\(fileExtension))")
    }
    
    public func feed(_ data: Data) {
        var offset = 0
        while offset < data.count {
            ringCondition.lock()

            // 计算环形缓冲区可用空间（保留 1 字节区分满/空）
            var available = (ringHead - ringTail - 1 + ringCapacity) % ringCapacity
            while available == 0 && !isRingClosed {
                ringCondition.wait()
                available = (ringHead - ringTail - 1 + ringCapacity) % ringCapacity
            }

            if isRingClosed {
                ringCondition.unlock()
                return
            }

            let chunkSize = min(data.count - offset, available)

            data.withUnsafeBytes { ptr in
                guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                let src = bytes + offset
                let firstPart = min(chunkSize, ringCapacity - ringTail)

                ringBuffer.withUnsafeMutableBytes { rbPtr in
                    guard let rbBase = rbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                    memcpy(rbBase + ringTail, src, firstPart)
                    if chunkSize > firstPart {
                        memcpy(rbBase, src + firstPart, chunkSize - firstPart)
                    }
                }
            }

            ringTail = (ringTail + chunkSize) % ringCapacity
            offset += chunkSize
            totalBytesReceived += Int64(chunkSize)

            ringCondition.signal()
            ringCondition.unlock()
        }
    }
    
    public func flush() {
        ringCondition.lock()
        isRingClosed = true
        ringCondition.broadcast()
        ringCondition.unlock()
    }
    
    public func seekOffset(for time: TimeInterval) -> Int64? {
        guard duration > 0, contentLength > 0 else { return nil }
        let ratio = time / duration
        return Int64(Double(contentLength) * ratio)
    }
    
    public func resetForSeek() {
        ringCondition.lock()
        isSeeking = true
        isRingClosed = false
        
        ringHead = 0
        ringTail = 0
        totalBytesReceived = 0
        
        ringCondition.broadcast()
        ringCondition.unlock()
        
        stateLock.lock()
        if let codecCtx = codecContext {
            avcodec_flush_buffers(codecCtx)
        }
        if let fmtCtx = formatContext {
            if let pb = fmtCtx.pointee.pb {
                pb.pointee.eof_reached = 0
                pb.pointee.error = 0
            }
        }
        
        ringCondition.lock()
        isSeeking = false
        ringCondition.unlock()
        
        stateLock.unlock()
    }
    
    public func close() {
        ringCondition.lock()
        isAborted = true
        isRingClosed = true
        ringCondition.broadcast()
        ringCondition.unlock()
        
        stateLock.lock()
        
        if let th = decoderThread, th.isExecuting {
            th.cancel()
        }
        decoderThread = nil
        
        if packet != nil {
            av_packet_free(&packet)
        }
        if decodedFrame != nil {
            av_frame_free(&decodedFrame)
        }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if let fmtCtx = formatContext {
            var ctx: UnsafeMutablePointer<AVFormatContext>? = fmtCtx
            avformat_close_input(&ctx)
            formatContext = nil
        }
        if let avio = avioContext {
            if let buf = avio.pointee.buffer {
                buf.deallocate()
            }
            avio_context_free(&avioContext)
        }
        resampler.close()
        stateLock.unlock()
    }
    
    public func updateDuration() {
        stateLock.lock()
        defer { stateLock.unlock() }
        recomputeDurationLocked()
    }

    /// Derives duration from FFmpeg metadata and, when needed, `Content-Length` + bitrate heuristics.
    /// Network Opus/Vorbis in Ogg often reports `AV_NOPTS` duration and container `bit_rate == 0`, so we
    /// also use per-stream duration, codec bit rates, and a conservative default bitrate when only size is known.
    private func recomputeDurationLocked() {
        guard let fmtCtx = formatContext, streamIndex >= 0 else { return }

        let fmt = fmtCtx.pointee

        if fmt.duration != CFFMPEG_AV_NOPTS_VALUE && fmt.duration > 0 {
            let d = Double(fmt.duration) / Double(AV_TIME_BASE)
            if d > 0 {
                duration = d
                return
            }
        }

        guard let streamPtr = fmt.streams[Int(streamIndex)] else { return }
        let st = streamPtr.pointee

        if st.duration != CFFMPEG_AV_NOPTS_VALUE && st.duration > 0 {
            let tb = st.time_base
            if tb.den != 0 {
                let q2d = Double(tb.num) / Double(tb.den)
                let d = Double(st.duration) * q2d
                if d > 0 {
                    duration = d
                    return
                }
            }
        }

        var br: Int64 = Int64(fmt.bit_rate)
        if br <= 0, let cp = st.codecpar {
            br = Int64(cp.pointee.bit_rate)
        }
        if br <= 0, let ctx = codecContext {
            br = Int64(ctx.pointee.bit_rate)
        }
        // Opus/Vorbis and many lossy streams leave container bitrate at 0; estimate from file size for UI/seek.
        if br <= 0, contentLength > 0 {
            let cid = st.codecpar?.pointee.codec_id ?? AV_CODEC_ID_NONE
            br = defaultBitrateForEstimate(codecId: cid)
        }

        if contentLength > 0, br > 0 {
            duration = Double(contentLength) * 8.0 / Double(br)
        }
    }

    /// Bits per second used only when FFmpeg reports no bitrate but we have `Content-Length` (typical Opus streaming).
    private func defaultBitrateForEstimate(codecId: AVCodecID) -> Int64 {
        switch codecId {
        case AV_CODEC_ID_OPUS:
            return 96_000
        case AV_CODEC_ID_VORBIS:
            return 128_000
        default:
            return 128_000
        }
    }
    
    // MARK: - Internal Decode Loop
    
    private func decodeLoop() {
        stateLock.lock()
        
        VILogger.debug("[VIA_FFMPEG_PUSH] decodeLoop started. fileExtension: \(fileExtension)")
        let urlStr = fileExtension.isEmpty ? nil : "dummy.\(fileExtension)"
        var openResult: Int32 = 0
        if let urlStr = urlStr {
            openResult = urlStr.withCString { ptr in
                VILogger.debug("[VIA_FFMPEG_PUSH] avformat_open_input with url: \(String(cString: ptr))")
                return avformat_open_input(&formatContext, ptr, nil, nil)
            }
        } else {
            VILogger.debug("[VIA_FFMPEG_PUSH] avformat_open_input with nil url")
            openResult = avformat_open_input(&formatContext, nil, nil, nil)
        }
        
        VILogger.debug("[VIA_FFMPEG_PUSH] avformat_open_input result: \(openResult)")
        
        // This is a blocking call that will read from our IO callback
        if openResult < 0 {
            formatContext = nil // Explicitly nil out just in case
            stateLock.unlock()
            
            ringCondition.lock()
            let aborted = isAborted
            ringCondition.unlock()
            
            if !aborted {
                onError?(VIDecoderError.fileOpenFailed(-2))
            }
            return
        }
        
        let findStreamRet = avformat_find_stream_info(formatContext, nil)
        VILogger.debug("[VIA_FFMPEG_PUSH] avformat_find_stream_info result: \(findStreamRet)")
        if findStreamRet < 0 {
            stateLock.unlock()
            
            ringCondition.lock()
            let aborted = isAborted
            ringCondition.unlock()
            
            if !aborted {
                onError?(VIDecoderError.fileOpenFailed(-3))
            }
            return
        }
        
        let streamIdx = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.unsupportedFormat("No audio stream found"))
            return
        }
        self.streamIndex = streamIdx
        
        let stream = formatContext!.pointee.streams[Int(streamIdx)]!
        let codecParams = stream.pointee.codecpar!
        
        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            stateLock.unlock()
            onError?(VIDecoderError.unsupportedFormat("Codec not found"))
            return
        }
        
        codecContext = avcodec_alloc_context3(codec)
        if avcodec_parameters_to_context(codecContext, codecParams) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-4))
            return
        }
        
        if avcodec_open2(codecContext, codec, nil) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-5))
            return
        }
        
        self.packet = av_packet_alloc()
        self.decodedFrame = av_frame_alloc()
        
        updateDuration()
        stateLock.unlock()
        
        // Main Decoding Loop
        while !Thread.current.isCancelled {
            stateLock.lock()
            // Content-Length often arrives after the first probe; refresh duration for Opus/Vorbis + size estimate.
            if duration <= 0 && contentLength > 0 {
                recomputeDurationLocked()
            }
            guard let fmtCtx = formatContext, let codecCtx = codecContext, let pkt = packet, let frame = decodedFrame else {
                stateLock.unlock()
                break
            }
            
            let readRet = av_read_frame(fmtCtx, pkt)
            if readRet < 0 {
                stateLock.unlock()
                
                ringCondition.lock()
                let aborted = isAborted
                let seeking = isSeeking
                let closed = isRingClosed
                ringCondition.unlock()
                
                if aborted {
                    break
                }
                
                if seeking {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                
                if readRet == CFFMPEG_AVERROR_EOF || closed {
                    onEndOfStream?()
                } else if readRet != CFFMPEG_AVERROR_EAGAIN {
                    onError?(VIDecoderError.decodeFailed(OSStatus(readRet)))
                }
                break
            }
            
            if pkt.pointee.stream_index == self.streamIndex {
                let sendRet = avcodec_send_packet(codecCtx, pkt)
                av_packet_unref(pkt)
                
                if sendRet < 0 && sendRet != CFFMPEG_AVERROR_EAGAIN && sendRet != CFFMPEG_AVERROR_EOF {
                    stateLock.unlock()
                    onError?(VIDecoderError.decodeFailed(OSStatus(sendRet)))
                    break
                }
                
                while true {
                    let recvRet = avcodec_receive_frame(codecCtx, frame)
                    if recvRet == CFFMPEG_AVERROR_EAGAIN || recvRet == CFFMPEG_AVERROR_EOF {
                        break
                    } else if recvRet < 0 {
                        stateLock.unlock()
                        onError?(VIDecoderError.decodeFailed(OSStatus(recvRet)))
                        return
                    }
                    
                    do {
                        let outFmt = try resampler.configure(with: frame)
                        if !_isFormatReady {
                            self._outputFormat = outFmt
                            _isFormatReady = true
                            
                            // Re-calculate duration before notifying format
                            updateDuration()
                            
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.onOutputFormatReady?(outFmt, self.duration)
                            }
                        }
                        
                        if let resampledPcm = resampler.resample(frame: frame) {
                            onBufferReady?(resampledPcm)
                        }
                    } catch {
                        stateLock.unlock()
                        onError?(error)
                        return
                    }
                    av_frame_unref(frame)
                }
            } else {
                av_packet_unref(pkt)
            }
            stateLock.unlock()
        }
    }
    
    deinit {
        close()
    }
    
    // MARK: - Ring Buffer Reader
    
    fileprivate func readData(buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        ringCondition.lock()
        defer { ringCondition.unlock() }
        
        readDataLogSerial += 1
        let n = readDataLogSerial
        if n <= 12 || n % 400 == 0 {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData #\(n) requested size: \(size)")
        }
        
        while ringHead == ringTail && !isRingClosed && !isAborted && !isSeeking {
            ringCondition.wait()
        }
        
        if isAborted || isSeeking || (ringHead == ringTail && isRingClosed) {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData EOF (#\(n)) aborted:\(isAborted) seeking:\(isSeeking) closed:\(isRingClosed)")
            return CFFMPEG_AVERROR_EOF
        }
        
        var available = 0
        if ringTail > ringHead {
            available = ringTail - ringHead
        } else {
            available = ringCapacity - ringHead + ringTail
        }
        
        let toRead = min(Int(size), available)
        if n <= 12 || n % 400 == 0 {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData #\(n) → \(toRead) bytes (available \(available))")
        }
        let firstPart = min(toRead, ringCapacity - ringHead)
        
        ringBuffer.withUnsafeBytes { rbPtr in
            guard let rbBase = rbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
            memcpy(buf, rbBase + ringHead, firstPart)
            if toRead > firstPart {
                memcpy(buf + firstPart, rbBase, toRead - firstPart)
            }
        }
        
        ringHead = (ringHead + toRead) % ringCapacity
        ringCondition.signal()
        return Int32(toRead)
    }
}

// MARK: - C Callbacks for AVIO

private func streamReadPacketCallback(opaque: UnsafeMutableRawPointer?, buf: UnsafeMutablePointer<UInt8>?, buf_size: Int32) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return 0 }
    let decoder = Unmanaged<VIFFmpegStreamDecoder>.fromOpaque(opaque).takeUnretainedValue()
    return decoder.readData(buf: buf, size: buf_size)
}
