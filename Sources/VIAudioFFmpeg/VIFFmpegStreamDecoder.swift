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
public final class VIFFmpegStreamDecoder: VIStreamDecoding {
    
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
    private let ringCapacity = 10 * 1024 * 1024 // 10MB ring buffer
    
    private let stateLock = NSRecursiveLock()
    private let ringCondition = NSCondition()
    
    private var decoderThread: Thread?
    private var _isFormatReady = false
    
    required public init() {
        ringBuffer = Data(count: ringCapacity)
        avformat_network_init()
    }
    
    public func open(fileTypeHint: AudioFileTypeID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        isRingClosed = false
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
            streamSeekCallback
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
    }
    
    public func feed(_ data: Data) {
        ringCondition.lock()
        
        // Wait if buffer is full
        while ((ringTail + data.count) % ringCapacity) == ringHead && !isRingClosed {
            ringCondition.wait()
        }
        
        if isRingClosed {
            ringCondition.unlock()
            return
        }
        
        totalBytesReceived += Int64(data.count)
        
        data.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            let firstPart = min(data.count, ringCapacity - ringTail)
            
            ringBuffer.withUnsafeMutableBytes { rbPtr in
                guard let rbBase = rbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                memcpy(rbBase + ringTail, bytes, firstPart)
                if data.count > firstPart {
                    memcpy(rbBase, bytes + firstPart, data.count - firstPart)
                }
            }
        }
        
        ringTail = (ringTail + data.count) % ringCapacity
        ringCondition.signal()
        ringCondition.unlock()
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
        stateLock.lock()
        ringCondition.lock()
        
        isRingClosed = false
        ringHead = 0
        ringTail = 0
        totalBytesReceived = 0
        
        if let codecCtx = codecContext {
            avcodec_flush_buffers(codecCtx)
        }
        
        ringCondition.broadcast()
        ringCondition.unlock()
        stateLock.unlock()
    }
    
    public func close() {
        stateLock.lock()
        ringCondition.lock()
        isRingClosed = true
        ringCondition.broadcast()
        ringCondition.unlock()
        
        if let th = decoderThread, th.isExecuting {
            th.cancel()
        }
        decoderThread = nil
        
        if let pkt = packet {
            av_packet_free(&packet)
        }
        if let frame = decodedFrame {
            av_frame_free(&decodedFrame)
        }
        if let codecCtx = codecContext {
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
        
        guard let fmtCtx = formatContext else { return }
        if fmtCtx.pointee.duration != CFFMPEG_AV_NOPTS_VALUE {
            self.duration = Double(fmtCtx.pointee.duration) / Double(AV_TIME_BASE)
        } else if contentLength > 0 && fmtCtx.pointee.bit_rate > 0 {
            self.duration = Double(contentLength) * 8.0 / Double(fmtCtx.pointee.bit_rate)
        }
    }
    
    // MARK: - Internal Decode Loop
    
    private func decodeLoop() {
        stateLock.lock()
        var formatCtx = formatContext
        
        // This is a blocking call that will read from our IO callback
        if avformat_open_input(&formatCtx, nil, nil, nil) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-2))
            return
        }
        
        if avformat_find_stream_info(formatCtx, nil) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-3))
            return
        }
        
        let streamIdx = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.unsupportedFormat("No audio stream found"))
            return
        }
        self.streamIndex = streamIdx
        
        let stream = formatCtx!.pointee.streams[Int(streamIdx)]!
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
            guard let fmtCtx = formatContext, let codecCtx = codecContext, let pkt = packet, let frame = decodedFrame else {
                stateLock.unlock()
                break
            }
            
            let readRet = av_read_frame(fmtCtx, pkt)
            if readRet < 0 {
                stateLock.unlock()
                if readRet == CFFMPEG_AVERROR_EOF {
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
        
        while ringHead == ringTail && !isRingClosed {
            ringCondition.wait()
        }
        
        if ringHead == ringTail && isRingClosed {
            return CFFMPEG_AVERROR_EOF
        }
        
        var available = 0
        if ringTail > ringHead {
            available = ringTail - ringHead
        } else {
            available = ringCapacity - ringHead + ringTail
        }
        
        let toRead = min(Int(size), available)
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

private func streamSeekCallback(opaque: UnsafeMutableRawPointer?, offset: Int64, whence: Int32) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let decoder = Unmanaged<VIFFmpegStreamDecoder>.fromOpaque(opaque).takeUnretainedValue()
    
    if whence == AVSEEK_SIZE {
        return decoder.contentLength > 0 ? decoder.contentLength : -1
    }
    
    // Stream mode doesn't support random access seek directly through avio.
    // Seek is handled by pushing new data after resetting.
    return -1
}
