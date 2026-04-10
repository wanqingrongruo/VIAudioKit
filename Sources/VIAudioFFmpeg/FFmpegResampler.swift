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
    private var lastInSampleFmt: AVSampleFormat = AV_SAMPLE_FMT_NONE
    private var outFormat: AVAudioFormat?
    
    init() {}
    
    deinit {
        close()
    }
    
    func close() {
        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }
        isConfigured = false
    }
    
    /// Initializes or re-initializes the SwrContext based on the incoming frame parameters.
    func configure(with frame: UnsafeMutablePointer<AVFrame>) throws -> AVAudioFormat {
        let inRate = frame.pointee.sample_rate
        let inChannels = frame.pointee.ch_layout.nb_channels
        var inLayout = frame.pointee.ch_layout
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
        if isConfigured, outSampleRate == targetRate, outChannels == targetChannels, lastInSampleFmt == inSampleFmt {
            return format
        }
        
        close()
        
        outSampleRate = targetRate
        outChannels = targetChannels
        lastInSampleFmt = inSampleFmt
        outFormat = format
        
        var targetLayout = AVChannelLayout()
        av_channel_layout_default(&targetLayout, targetChannels)
        
        if inLayout.nb_channels == 0 {
            av_channel_layout_default(&inLayout, inChannels > 0 ? inChannels : targetChannels)
        }
        
        var ctx: OpaquePointer? = nil
        let ret = swr_alloc_set_opts2(
            &ctx,
            &targetLayout,
            AV_SAMPLE_FMT_FLTP,
            targetRate,
            &inLayout,
            inSampleFmt,
            inRate,
            0,
            nil
        )
        
        if ret < 0 || ctx == nil {
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
