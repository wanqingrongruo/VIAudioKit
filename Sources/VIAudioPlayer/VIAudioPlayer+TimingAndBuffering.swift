import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
#endif

// MARK: - 缓冲状态机、时间更新、辅助方法

extension VIAudioPlayer {

    // MARK: - Buffering state machine (Network mode)

    /// Called after a buffer is enqueued (network push path).
    /// Checks whether we have enough buffered audio to transition from
    /// `.buffering` to `.playing`. Must be called on the main queue.
    func checkBufferingToPlaying() {
        guard isNetworkMode, state == .buffering, playWhenReady else { return }

        let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
        let required = requiredBufferDuration()
        let enoughData = accumulated >= required || (streamEndReached && accumulated > 0)

        guard enoughData else { return }

        bufferingReason = nil
        state = .playing
        startNetworkRendererAsync()
        VILogger.debug("[VIAudioPlayer] buffering → playing (accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s scheduled=\(renderer.scheduledBufferCount))")
    }

    /// Check if stream has ended and all buffers consumed.
    func checkStreamFinished() {
        guard isNetworkMode, streamEndReached else { return }
        guard bufferQueue.isEmpty, renderer.scheduledBufferCount == 0 else { return }

        let gen: Int = stateQueue.sync { loadGeneration }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // 校验 loadGeneration 防止在延迟期间切换了曲目
            let stale: Bool = self.stateQueue.sync { gen != self.loadGeneration }
            guard !stale else { return }
            if self.streamEndReached, self.bufferQueue.isEmpty,
               self.renderer.scheduledBufferCount == 0,
               self.state == .playing || self.state == .buffering {
                self.state = .finished
                self.stopTimeUpdates()
            }
        }
    }

    /// Returns the required buffer duration before starting/resuming playback.
    func requiredBufferDuration() -> TimeInterval {
        switch bufferingReason {
        case .initialLoad:
            return configuration.secondsRequiredToStartPlaying
        case .afterSeek:
            return configuration.secondsRequiredAfterSeek
        case .underrun:
            return configuration.secondsRequiredAfterBufferUnderrun
        case .none:
            return configuration.secondsRequiredToStartPlaying
        }
    }

    /// Called periodically to detect buffer underruns (network mode).
    func checkForBufferUnderrun() {
        guard isNetworkMode, state == .playing else { return }
        guard !streamEndReached else { return }

        if renderer.scheduledBufferCount == 0 && bufferQueue.isEmpty {
            VILogger.debug("[VIAudioPlayer] buffer underrun detected, entering buffering state")
            let rendererTime = renderer.currentPlaybackTime
            playbackBaseTime += rendererTime
            renderer.stop()
            stateQueue.sync { networkBufferedDuration = 0 }
            bufferingReason = .underrun
            state = .buffering
            notifyBufferState()
        }
    }

    // MARK: - Time updates

    func startTimeUpdates() {
        stopTimeUpdates()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: configuration.timeUpdateInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            if self.state == .playing {
                self.updateCurrentTime()
                self.checkForBufferUnderrun()
                if self.isNetworkMode {
                    self.checkStreamFinished()
                    self.notifyBufferState()
                }
            } else if self.state == .buffering {
                // While buffering, still surface duration once the stream decoder knows it (e.g. FFmpeg + Content-Length).
                if self.duration == 0, let sd = self.streamDecoder, sd.duration > 0 {
                    self.duration = sd.duration
                    self.delegate?.player(self, didUpdateTime: self.currentTime, duration: self.duration)
                }
                self.checkBufferingToPlaying()
                if self.isNetworkMode { self.notifyBufferState() }
            }
        }
        timer.resume()
        self.timeUpdateTimer = timer
    }

    func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    func updateCurrentTime() {
        let seeking: Bool = stateQueue.sync { isSeeking }
        guard !seeking else { return }

        // Lazily pick up duration from the stream decoder when ours is still 0
        // (bitrate may arrive after onOutputFormatReady).
        if duration == 0, let sd = streamDecoder, sd.duration > 0 {
            duration = sd.duration
        }

        let rendererTime = renderer.currentPlaybackTime
        let time = playbackBaseTime + rendererTime
        let clampedTime = duration > 0 ? min(time, duration) : time
        guard clampedTime.isFinite else { return }
        currentTime = clampedTime
        delegate?.player(self, didUpdateTime: clampedTime, duration: duration)
    }

    // MARK: - Buffer state notification

    /// Must be called on the main queue (from the timer handler).
    func notifyBufferState() {
        guard isNetworkMode else { return }

        let bufferState: VIBufferState
        if streamEndReached {
            bufferState = .full
        } else {
            let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
            let required = requiredBufferDuration()
            if accumulated <= 0 {
                bufferState = .empty
            } else if accumulated >= required {
                bufferState = .sufficient
            } else {
                let progress = Float(accumulated / required)
                bufferState = .buffering(progress: min(progress, 1.0))
            }
        }

        delegate?.player(self, didUpdateBuffer: bufferState)
    }

    // MARK: - Helpers

    func wrapError(_ error: Error) -> VIPlayerError {
        if let pe = error as? VIPlayerError { return pe }
        if let se = error as? VIAudioSourceError { return .networkError(se) }
        return .decoderCreationFailed(error)
    }
}
