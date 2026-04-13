import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDecoder
#endif

#if COCOAPODS && canImport(CFFmpeg)
import CFFmpeg

/// 基于 FFmpeg C API 的推送模式流解码器。
/// 支持 OGG、WMA、APE、FLAC、M4A 等格式。
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

    /// 累计接收字节数，由 VIRingBuffer 统计
    public var totalBytesReceived: Int64 {
        return ringBuffer.totalBytesWritten
    }

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var avioContext: UnsafeMutablePointer<AVIOContext>?
    private var streamIndex: Int32 = -1
    private var ioBuffer: UnsafeMutablePointer<UInt8>?
    private let ioBufferSize = 32768

    private var resampler = FFmpegResampler()
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?

    /// 环形缓冲区，用于接收推送数据并供 AVIO 回调读取
    let ringBuffer = VIRingBuffer(capacity: 10 * 1024 * 1024)

    private let stateLock = NSRecursiveLock()

    private var decoderThread: Thread?
    private var _isFormatReady = false
    public var fileExtension: String = ""
    /// 仅用于诊断：限制 readData 日志条数，避免探测阶段刷屏
    private var readDataLogSerial: Int = 0

    required public init() {
        avformat_network_init()
    }

    public func open(fileTypeHint: AudioFileTypeID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        ringBuffer.reset()

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

        // 启动解码线程
        decoderThread = Thread { [weak self] in
            self?.decodeLoop()
        }
        decoderThread?.name = "com.viaudiokit.ffmpeg.stream"
        decoderThread?.start()
        VILogger.debug("[VIA_FFMPEG_PUSH] open() OK, decode thread started (ext=\(fileExtension))")
    }

    public func feed(_ data: Data) {
        ringBuffer.write(data)
    }

    public func flush() {
        ringBuffer.close()
    }

    public func seekOffset(for time: TimeInterval) -> Int64? {
        guard duration > 0, contentLength > 0 else { return nil }
        let ratio = time / duration
        return Int64(Double(contentLength) * ratio)
    }

    public func resetForSeek() {
        ringBuffer.beginSeek()

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
        stateLock.unlock()

        ringBuffer.endSeek()
    }

    public func close() {
        // 先中止环形缓冲区，确保 readData 立即返回
        ringBuffer.abort()

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

    /// 根据 FFmpeg 元数据以及 Content-Length + 比特率启发式方法推导时长。
    /// 网络 Opus/Vorbis（Ogg 封装）经常报告 AV_NOPTS 时长且容器 bit_rate == 0，
    /// 因此还会使用每个流的时长、编解码器比特率和保守的默认比特率。
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
        // Opus/Vorbis 等有损流经常将容器比特率置为 0；从文件大小估算以供 UI/seek 使用
        if br <= 0, contentLength > 0 {
            let cid = st.codecpar?.pointee.codec_id ?? AV_CODEC_ID_NONE
            br = defaultBitrateForEstimate(codecId: cid)
        }

        if contentLength > 0, br > 0 {
            duration = Double(contentLength) * 8.0 / Double(br)
        }
    }

    /// 仅当 FFmpeg 未报告比特率但有 Content-Length 时使用的每秒比特数（典型 Opus 流场景）
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

    // MARK: - 解码主流程

    /// 解码主循环入口，依次执行格式探测、流发现和包解码
    private func decodeLoop() {
        guard openFormatContext() else { return }
        guard discoverStream() else { return }
        runPacketDecodeLoop()
    }

    /// 打开 FFmpeg 格式上下文并探测流信息。
    /// - Returns: 成功返回 `true`，失败时调用 `onError` 并返回 `false`
    private func openFormatContext() -> Bool {
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

        if openResult < 0 {
            formatContext = nil
            stateLock.unlock()

            if !ringBuffer.isAborted {
                onError?(VIDecoderError.fileOpenFailed(-2))
            }
            return false
        }

        let findStreamRet = avformat_find_stream_info(formatContext, nil)
        VILogger.debug("[VIA_FFMPEG_PUSH] avformat_find_stream_info result: \(findStreamRet)")
        if findStreamRet < 0 {
            stateLock.unlock()

            if !ringBuffer.isAborted {
                onError?(VIDecoderError.fileOpenFailed(-3))
            }
            return false
        }

        // 注意：此处 stateLock 仍处于锁定状态，由 discoverStream() 继续持有
        return true
    }

    /// 寻找最佳音频流，打开编解码器，分配 packet/frame，并计算时长。
    /// - Returns: 成功返回 `true`，失败时调用 `onError` 并返回 `false`
    /// - Note: 进入时 stateLock 处于锁定状态，正常退出时会解锁
    private func discoverStream() -> Bool {
        let streamIdx = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.unsupportedFormat("No audio stream found"))
            return false
        }
        self.streamIndex = streamIdx

        let stream = formatContext!.pointee.streams[Int(streamIdx)]!
        let codecParams = stream.pointee.codecpar!

        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            stateLock.unlock()
            onError?(VIDecoderError.unsupportedFormat("Codec not found"))
            return false
        }

        codecContext = avcodec_alloc_context3(codec)
        if avcodec_parameters_to_context(codecContext, codecParams) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-4))
            return false
        }

        if avcodec_open2(codecContext, codec, nil) < 0 {
            stateLock.unlock()
            onError?(VIDecoderError.fileOpenFailed(-5))
            return false
        }

        self.packet = av_packet_alloc()
        self.decodedFrame = av_frame_alloc()

        updateDuration()
        stateLock.unlock()

        return true
    }

    /// 包读取-解码主循环：持续读取 packet、解码 frame、重采样并回调输出
    private func runPacketDecodeLoop() {
        while !Thread.current.isCancelled {
            stateLock.lock()
            // Content-Length 通常在首次探测后到达；为 Opus/Vorbis + 大小估算刷新时长
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

                if ringBuffer.isAborted {
                    break
                }

                if ringBuffer.isSeeking {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                if readRet == CFFMPEG_AVERROR_EOF || ringBuffer.isClosed {
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

                            // 在通知格式前重新计算时长
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

    // MARK: - 环形缓冲区读取回调

    /// 供 AVIO C 回调调用，从环形缓冲区读取数据
    fileprivate func readData(buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        readDataLogSerial += 1
        let n = readDataLogSerial
        if n <= 12 || n % 400 == 0 {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData #\(n) requested size: \(size)")
        }

        let result = ringBuffer.read(into: buf, size: size)

        if result == -1 {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData EOF (#\(n)) aborted:\(ringBuffer.isAborted) seeking:\(ringBuffer.isSeeking) closed:\(ringBuffer.isClosed)")
            return CFFMPEG_AVERROR_EOF
        }

        if n <= 12 || n % 400 == 0 {
            VILogger.debug("[VIA_FFMPEG_PUSH] readData #\(n) → \(result) bytes")
        }
        return result
    }
}

// MARK: - AVIO C 回调

private func streamReadPacketCallback(opaque: UnsafeMutableRawPointer?, buf: UnsafeMutablePointer<UInt8>?, buf_size: Int32) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return 0 }
    let decoder = Unmanaged<VIFFmpegStreamDecoder>.fromOpaque(opaque).takeUnretainedValue()
    return decoder.readData(buf: buf, size: buf_size)
}

#endif
