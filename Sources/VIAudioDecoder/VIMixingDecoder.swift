import Foundation
import AVFoundation
import Accelerate

/// A custom decoder that mixes multiple local audio files into a single stream.
/// Use a `.vimix` file containing a JSON array of file URLs to initialize.
public final class VIMixingDecoder: VIAudioDecoding {

    public static let supportedExtensions: Set<String> = ["vimix"]

    public let outputFormat: AVAudioFormat
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0

    private var decoders: [VINativeDecoder] = []
    private var tempBuffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()

    public required init(source: VIAudioSource) throws {
        // Only supports local files
        guard source.url.isFileURL else {
            throw VIDecoderError.unsupportedFormat("VIMixingDecoder only supports local files.")
        }
        
        let data = try Data(contentsOf: source.url)
        guard let urlStrings = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw VIDecoderError.unsupportedFormat("Invalid .vimix JSON format")
        }

        var maxDuration: TimeInterval = 0
        var firstFormat: AVAudioFormat? = nil

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            do {
                let subSource = try VILocalFileSource(fileURL: url)
                let decoder = try VINativeDecoder(source: subSource)
                decoders.append(decoder)
                
                if firstFormat == nil {
                    firstFormat = decoder.outputFormat
                }
                maxDuration = max(maxDuration, decoder.duration)
            } catch {
                VILogger.warning("[VIMixingDecoder] Failed to load track: \(url.lastPathComponent) - \(error)")
            }
        }

        guard !decoders.isEmpty, let fmt = firstFormat else {
            throw VIDecoderError.unsupportedFormat("No valid audio streams found in .vimix")
        }

        self.outputFormat = fmt
        self.duration = maxDuration
    }

    public func decode(into buffer: AVAudioPCMBuffer) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Setup temp buffers if needed
        if tempBuffers.count != decoders.count {
            tempBuffers = decoders.compactMap { _ in
                AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameCapacity)
            }
            // 如果某些 buffer 创建失败导致数量不匹配，无法安全继续
            guard tempBuffers.count == decoders.count else {
                VILogger.warning("[VIMixingDecoder] tempBuffers count (\(tempBuffers.count)) != decoders count (\(decoders.count)), aborting decode")
                return false
            }
        }

        var maxFrames: AVAudioFrameCount = 0
        var activeBuffers: [AVAudioPCMBuffer] = []

        for (i, decoder) in decoders.enumerated() {
            let tempBuf = tempBuffers[i]
            tempBuf.frameLength = tempBuf.frameCapacity
            if (try? decoder.decode(into: tempBuf)) == true, tempBuf.frameLength > 0 {
                maxFrames = max(maxFrames, tempBuf.frameLength)
                activeBuffers.append(tempBuf)
            }
        }

        guard maxFrames > 0 else {
            return false
        }

        buffer.frameLength = maxFrames
        let channelCount = Int(outputFormat.channelCount)
        guard let outData = buffer.floatChannelData else { return false }

        // Clear output buffer
        for ch in 0..<channelCount {
            vDSP_vclr(outData[ch], 1, vDSP_Length(maxFrames))
        }

        // Mix
        for tempBuf in activeBuffers {
            guard let inData = tempBuf.floatChannelData else { continue }
            let frames = vDSP_Length(tempBuf.frameLength)
            for ch in 0..<channelCount {
                vDSP_vadd(inData[ch], 1, outData[ch], 1, outData[ch], 1, frames)
            }
        }

        // Hard clipping to avoid overflow and distortion
        var low: Float = -1.0
        var high: Float = 1.0
        for ch in 0..<channelCount {
            vDSP_vclip(outData[ch], 1, &low, &high, outData[ch], 1, vDSP_Length(maxFrames))
        }

        // Update current time from the first active decoder
        currentTime = decoders.first?.currentTime ?? currentTime

        return true
    }

    public func seek(to time: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }

        for decoder in decoders {
            try decoder.seek(to: time)
        }
        currentTime = time
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        for decoder in decoders {
            decoder.close()
        }
        decoders.removeAll()
        tempBuffers.removeAll()
    }
}