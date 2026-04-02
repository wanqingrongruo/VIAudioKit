import Foundation
import AVFoundation

#if canImport(CFFmpeg)
import CFFmpeg
#endif

/// Converts decoded FFmpeg frames (any format/layout) to Float32 non-interleaved PCM buffers.
internal class FFmpegResampler {
    
    private var swrContext: OpaquePointer?
    private var isConfigured = false
    
    private var outSampleRate: Int32 = 0
    private var outChannels: Int32 = 0
    private var outFormat: AVAudioFormat?
    
    init() {}
    
    deinit {
        close()
    }
    
    func close() {
        if let ctx = swrContext {
            swr_free(&swrContext)
            swrContext = nil
        }
        isConfigured = false
    }
    
    /// Initializes or re-initializes the SwrContext based on the incoming frame parameters.
    func configure(with frame: UnsafeMutablePointer<AVFrame>) throws -> AVAudioFormat {
        let inRate = frame.pointee.sample_rate
        let inChannels = frame.pointee.channels
        let inChannelLayout = frame.pointee.channel_layout
        let inSampleFmt = AVSampleFormat(rawValue: frame.pointee.format)
        
        let targetRate = inRate > 0 ? inRate : 44100
        let targetChannels = inChannels > 0 ? inChannels : 2
        
        // We target standard AVAudioFormat: Float32, non-interleaved
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: AVAudioChannelCount(targetChannels),
            interleaved: false
        ) else {
            throw NSError(domain: "VIAudioFFmpeg", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid target format"])
        }
        
        // If context exists but parameters changed, we close it and recreate
        if isConfigured, outSampleRate == targetRate, outChannels == targetChannels {
            return format
        }
        
        close()
        
        outSampleRate = targetRate
        outChannels = targetChannels
        outFormat = format
        
        let targetChannelLayout = (targetChannels == 1) ? 4 : 3 // 4 is AV_CH_LAYOUT_MONO, 3 is AV_CH_LAYOUT_STEREO
        
        var ctx: OpaquePointer? = swr_alloc_set_opts(
            nil,
            Int64(targetChannelLayout),
            AV_SAMPLE_FMT_FLTP,
            targetRate,
            Int64(inChannelLayout == 0 ? ((inChannels == 1) ? 4 : 3) : inChannelLayout),
            inSampleFmt,
            inRate,
            0,
            nil
        )
        
        if ctx == nil {
            throw NSError(domain: "VIAudioFFmpeg", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate SwrContext"])
        }
        
        if swr_init(ctx) < 0 {
            swr_free(&ctx)
            throw NSError(domain: "VIAudioFFmpeg", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to init SwrContext"])
        }
        
        swrContext = ctx
        isConfigured = true
        return format
    }
    
    /// Resamples an AVFrame and produces an AVAudioPCMBuffer.
    func resample(frame: UnsafeMutablePointer<AVFrame>) -> AVAudioPCMBuffer? {
        guard isConfigured, let ctx = swrContext, let format = outFormat else { return nil }
        
        let inSamples = frame.pointee.nb_samples
        let outSamplesMax = av_rescale_rnd(
            swr_get_delay(ctx, Int64(frame.pointee.sample_rate)) + Int64(inSamples),
            Int64(outSampleRate),
            Int64(frame.pointee.sample_rate),
            AV_ROUND_UP
        )
        
        guard outSamplesMax > 0 else { return nil }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outSamplesMax)) else {
            return nil
        }
        
        // Create an array of pointers to the pcmBuffer's channel data
        let channelsCount = Int(format.channelCount)
        var outPointers = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: channelsCount)
        for i in 0..<channelsCount {
            if let floatData = pcmBuffer.floatChannelData {
                outPointers[i] = UnsafeMutableRawPointer(floatData[i]).assumingMemoryBound(to: UInt8.self)
            }
        }
        
        let inData = UnsafeMutableRawPointer(frame.pointee.extended_data)?.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let outSamples = outPointers.withUnsafeMutableBufferPointer { ptr -> Int32 in
            return swr_convert(
                ctx,
                ptr.baseAddress,
                Int32(outSamplesMax),
                inData,
                inSamples
            )
        }
        
        if outSamples < 0 {
            return nil
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(outSamples)
        return pcmBuffer
    }
}
