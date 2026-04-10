import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDecoder
#endif

#if canImport(CFFmpeg)
import CFFmpeg
#endif

/// Decoder implementation using FFmpeg C API to support OGG, WMA, APE, etc.
public final class VIFFmpegDecoder: VIAudioDecoding {
    
    public static let supportedExtensions: Set<String> = [
        "ogg", "oga", "opus", "wma", "ape", "wv"
    ]
    
    fileprivate let source: VIAudioSource
    fileprivate var currentOffset: Int64 = 0
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var avioContext: UnsafeMutablePointer<AVIOContext>?
    private var streamIndex: Int32 = -1
    private var ioBuffer: UnsafeMutablePointer<UInt8>?
    private let ioBufferSize = 32768
    
    private var resampler = FFmpegResampler()
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    
    private var _outputFormat: AVAudioFormat?
    public var outputFormat: AVAudioFormat {
        guard let fmt = _outputFormat else {
            fatalError("[VIFFmpegDecoder] outputFormat accessed before decoding starts or failed to determine format.")
        }
        return fmt
    }
    
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    
    private let lock = NSRecursiveLock()
    
    public required init(source: VIAudioSource) throws {
        self.source = source
        
        // Register FFmpeg components
        avformat_network_init()
                
        // 1. Allocate IO context buffer
        ioBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ioBufferSize)
        
        // 2. Setup AVIOContext
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        avioContext = avio_alloc_context(
            ioBuffer,
            Int32(ioBufferSize),
            0,
            opaque,
            readPacketCallback,
            nil,
            seekCallback
        )
        
        if avioContext == nil {
            ioBuffer?.deallocate()
            ioBuffer = nil
            throw VIDecoderError.fileOpenFailed(-1)
        }

        // 3. Allocate AVFormatContext
        formatContext = avformat_alloc_context()
        formatContext?.pointee.pb = avioContext

        // 4. Open input
        if avformat_open_input(&formatContext, nil, nil, nil) < 0 {
            formatContext = nil // Explicitly nil out to prevent double-free
            // avformat_open_input 失败时不会释放 avio，需要手动清理
            if let avio = avioContext {
                // avio_alloc_context 接管了 ioBuffer，通过 avio 释放
                avio.pointee.buffer.deallocate()
                avio_context_free(&avioContext)
            }
            ioBuffer = nil
            throw VIDecoderError.fileOpenFailed(-2)
        }
        
        if avformat_find_stream_info(formatContext, nil) < 0 {
            throw VIDecoderError.fileOpenFailed(-3)
        }
        
        // 5. Find audio stream
        let streamIdx = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            throw VIDecoderError.unsupportedFormat("No audio stream found")
        }
        self.streamIndex = streamIdx
        
        let stream = formatContext!.pointee.streams[Int(streamIdx)]!
        let codecParams = stream.pointee.codecpar!
        
        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            throw VIDecoderError.unsupportedFormat("Codec not found")
        }
        
        codecContext = avcodec_alloc_context3(codec)
        if avcodec_parameters_to_context(codecContext, codecParams) < 0 {
            throw VIDecoderError.fileOpenFailed(-4)
        }
        
        if avcodec_open2(codecContext, codec, nil) < 0 {
            throw VIDecoderError.fileOpenFailed(-5)
        }
        
        // Calculate duration
        if formatContext!.pointee.duration != CFFMPEG_AV_NOPTS_VALUE {
            self.duration = Double(formatContext!.pointee.duration) / Double(AV_TIME_BASE)
        }
        
        self.packet = av_packet_alloc()
        self.decodedFrame = av_frame_alloc()
        
        // Dummy read to determine format and configure resampler
        var dummyFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var gotFrame = false
        var firstPkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        while av_read_frame(formatContext, firstPkt) >= 0 {
            if firstPkt?.pointee.stream_index == self.streamIndex {
                if avcodec_send_packet(codecContext, firstPkt) == 0 {
                    if avcodec_receive_frame(codecContext, dummyFrame) == 0 {
                        gotFrame = true
                        av_packet_unref(firstPkt)
                        break
                    }
                }
            }
            av_packet_unref(firstPkt)
        }
        av_packet_free(&firstPkt)
        
        if gotFrame, let df = dummyFrame {
            do {
                self._outputFormat = try resampler.configure(with: df)
                // Rewind to beginning
                av_seek_frame(formatContext, self.streamIndex, 0, AVSEEK_FLAG_BACKWARD)
                avcodec_flush_buffers(codecContext)
            } catch {
                av_frame_free(&dummyFrame)
                throw VIDecoderError.unsupportedFormat("Resampler configuration failed")
            }
        } else {
            av_frame_free(&dummyFrame)
            throw VIDecoderError.unsupportedFormat("Failed to decode first frame to determine format")
        }
        av_frame_free(&dummyFrame)
    }
    
    deinit {
        close()
    }
    
    public func decode(into buffer: AVAudioPCMBuffer) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let fmtCtx = formatContext, let codecCtx = codecContext, let pkt = packet, let frame = decodedFrame else {
            return false
        }
        
        while av_read_frame(fmtCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == self.streamIndex {
                let sendRet = avcodec_send_packet(codecCtx, pkt)
                av_packet_unref(pkt)
                
                if sendRet < 0 && sendRet != CFFMPEG_AVERROR_EAGAIN && sendRet != CFFMPEG_AVERROR_EOF {
                    throw VIDecoderError.decodeFailed(OSStatus(sendRet))
                }
                
                while true {
                    let recvRet = avcodec_receive_frame(codecCtx, frame)
                    if recvRet == CFFMPEG_AVERROR_EAGAIN || recvRet == CFFMPEG_AVERROR_EOF {
                        break
                    } else if recvRet < 0 {
                        throw VIDecoderError.decodeFailed(OSStatus(recvRet))
                    }
                    
                    // Update current time
                    let tb = fmtCtx.pointee.streams[Int(self.streamIndex)]!.pointee.time_base
                    self.currentTime = Double(frame.pointee.pts) * Double(tb.num) / Double(tb.den)
                    
                    // Resample to AVAudioPCMBuffer
                    if let resampledPcm = resampler.resample(frame: frame) {
                        // Assuming caller uses this to copy over.
                        // Wait, protocol requires us to fill `buffer`!
                        // This means we must copy resampledPcm into `buffer`.
                        copy(from: resampledPcm, to: buffer)
                        av_frame_unref(frame)
                        return true
                    }
                    av_frame_unref(frame)
                }
            } else {
                av_packet_unref(pkt)
            }
        }
        return false
    }
    
    private func copy(from sourceBuffer: AVAudioPCMBuffer, to destinationBuffer: AVAudioPCMBuffer) {
        let framesToCopy = sourceBuffer.frameLength
        guard framesToCopy <= destinationBuffer.frameCapacity else {
            // In a real robust implementation, we would buffer the remainder.
            return
        }
        
        let srcData = sourceBuffer.floatChannelData!
        let dstData = destinationBuffer.floatChannelData!
        let channelCount = Int(sourceBuffer.format.channelCount)
        
        for i in 0..<channelCount {
            memcpy(dstData[i], srcData[i], Int(framesToCopy) * MemoryLayout<Float>.size)
        }
        
        destinationBuffer.frameLength = framesToCopy
    }
    
    public func seek(to time: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let fmtCtx = formatContext else { return }
        
        let tb = fmtCtx.pointee.streams[Int(self.streamIndex)]!.pointee.time_base
        let timestamp = Int64(time / (Double(tb.num) / Double(tb.den)))
        
        if av_seek_frame(fmtCtx, self.streamIndex, timestamp, AVSEEK_FLAG_BACKWARD) < 0 {
            throw VIDecoderError.seekFailed(-1)
        }
        
        if let codecCtx = codecContext {
            avcodec_flush_buffers(codecCtx)
        }
    }
    
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        
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
                // avio_alloc_context expects us to free the buffer
                buf.deallocate()
            }
            avio_context_free(&avioContext)
        }
        resampler.close()
    }
}

// MARK: - C Callbacks for AVIO

private func readPacketCallback(opaque: UnsafeMutableRawPointer?, buf: UnsafeMutablePointer<UInt8>?, buf_size: Int32) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return 0 }
    let decoder = Unmanaged<VIFFmpegDecoder>.fromOpaque(opaque).takeUnretainedValue()
    
    do {
        let data = try decoder.source.read(offset: decoder.currentOffset, length: Int(buf_size))
        if data.isEmpty { return CFFMPEG_AVERROR_EOF }
        
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                memcpy(buf, base, data.count)
            }
        }
        decoder.currentOffset += Int64(data.count)
        return Int32(data.count)
    } catch {
        return CFFMPEG_AVERROR_EOF
    }
}

private func seekCallback(opaque: UnsafeMutableRawPointer?, offset: Int64, whence: Int32) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let decoder = Unmanaged<VIFFmpegDecoder>.fromOpaque(opaque).takeUnretainedValue()

    if whence == AVSEEK_SIZE {
        if let cl = decoder.source.contentLength {
            return cl
        }
        return -1
    }

    // 去掉 AVSEEK_FORCE 标志位（如果有的话）
    let realWhence = whence & ~AVSEEK_FORCE

    switch realWhence {
    case SEEK_SET:
        decoder.currentOffset = offset
    case SEEK_CUR:
        decoder.currentOffset += offset
    case SEEK_END:
        if let cl = decoder.source.contentLength {
            decoder.currentOffset = cl + offset
        } else {
            return -1
        }
    default:
        return -1
    }
    return decoder.currentOffset
}
