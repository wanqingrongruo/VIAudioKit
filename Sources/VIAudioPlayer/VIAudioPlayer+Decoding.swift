import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
#endif

// MARK: - 解码线程与缓冲区填充

extension VIAudioPlayer {

    // MARK: - Decode thread (Pull mode only)

    func startDecoding() {
        shouldStopDecoding = false
        bufferQueue.reset()
        decodeQueue.async { [weak self] in
            self?.decodeLoop()
        }
    }

    func stopDecoding() {
        shouldStopDecoding = true
        bufferQueue.flush()
    }

    func decodeLoop() {
        guard let decoder = decoder else {
            VILogger.debug("[VIAudioPlayer] decodeLoop: decoder is nil, aborting")
            return
        }
        let format = decoder.outputFormat
        VILogger.debug("[VIAudioPlayer] decodeLoop started, format: \(format)")

        while !shouldStopDecoding {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: configuration.framesPerBuffer
            ) else {
                VILogger.debug("[VIAudioPlayer] decodeLoop: failed to create PCM buffer")
                break
            }

            do {
                let hasMore = try decoder.decode(into: buffer)
                guard buffer.frameLength > 0 else {
                    if !hasMore {
                        VILogger.debug("[VIAudioPlayer] decodeLoop: end of stream reached")
                        feedRenderer()
                        waitForPlaybackFinish()
                        break
                    }
                    continue
                }

                let enqueued = bufferQueue.enqueue(buffer)
                if !enqueued {
                    VILogger.debug("[VIAudioPlayer] decodeLoop: enqueue returned false (flushing or stopped)")
                    break
                }

                feedRenderer()

                if !hasMore {
                    VILogger.debug("[VIAudioPlayer] decodeLoop: last buffer decoded, draining")
                    feedRenderer()
                    waitForPlaybackFinish()
                    break
                }
            } catch {
                if !shouldStopDecoding {
                    VILogger.debug("[VIAudioPlayer] decodeLoop error: \(error)")
                    let playerError = VIPlayerError.decodingFailed(error)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.state = .failed(playerError)
                        self.delegate?.player(self, didReceiveError: playerError)
                    }
                }
                break
            }
        }
        VILogger.debug("[VIAudioPlayer] decodeLoop exited, shouldStop=\(shouldStopDecoding)")
    }

    // MARK: - Buffer feeding

    /// Schedule decoded buffers into renderer in small batches.
    /// This avoids monopolizing the main thread when network push produces
    /// many buffers quickly.
    func feedRenderer(maxBuffers: Int = 8) {
        var scheduled = 0
        while scheduled < maxBuffers, let buffer = bufferQueue.dequeue() {
            renderer.scheduleBuffer(buffer)
            scheduled += 1
        }
    }

    /// Start renderer playback on a dedicated queue so slow system audio calls
    /// (e.g. first AVAudioSession activation) do not block the main thread.
    func startNetworkRendererAsync() {
        let fmt = streamDecoder?.outputFormat
        renderControlQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .playing else { return }

            if let fmt, !self.renderer.isPrepared {
                do {
                    try self.renderer.prepare(format: fmt)
                } catch {
                    let playerError = VIPlayerError.renderingFailed(error)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.state = .failed(playerError)
                        self.delegate?.player(self, didReceiveError: playerError)
                    }
                    return
                }
            }

            self.renderer.rate = self.desiredRate
            self.feedRenderer()
            do {
                try self.renderer.play()
            } catch {
                let playerError = VIPlayerError.renderingFailed(error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state = .failed(playerError)
                    self.delegate?.player(self, didReceiveError: playerError)
                }
            }
        }
    }

    func waitForPlaybackFinish() {
        while renderer.scheduledBufferCount > 0 && !shouldStopDecoding {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !shouldStopDecoding else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // For network mode, only finish if the stream truly ended
            if self.isNetworkMode && !self.streamEndReached { return }
            self.state = .finished
            self.stopTimeUpdates()
        }
    }

}
