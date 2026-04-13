import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
#endif

// MARK: - 播放控制、Seek、缓存管理

extension VIAudioPlayer {

    // MARK: - Play

    public func play() {
        playWhenReady = true
        
        if isNetworkMode {
            // Accept play() in any state for network mode (including preparing/buffering)
            guard state == .ready || state == .paused || state == .buffering || state == .preparing else { return }
            pushSource?.resume()

            let accumulated: TimeInterval = stateQueue.sync { networkBufferedDuration }
            let required = requiredBufferDuration()
            VILogger.debug("[VIAudioPlayer] play(): network mode, accumulated=\(String(format: "%.2f", accumulated))s required=\(String(format: "%.2f", required))s streamEnd=\(streamEndReached)")

            if accumulated >= required || (streamEndReached && accumulated > 0) {
                state = .playing
                startNetworkRendererAsync()
                bufferingReason = nil
                VILogger.debug("[VIAudioPlayer] play(): immediate transition to playing")
            } else {
                if state != .buffering {
                    bufferingReason = .initialLoad
                    state = .buffering
                }
            }
            startTimeUpdates()
            return
        }

        guard state == .ready || state == .paused || state == .preparing else { return }
        if state == .preparing { return }

        state = .playing
        renderer.rate = desiredRate
        do {
            try renderer.play()
        } catch {
            let playerError = VIPlayerError.renderingFailed(error)
            state = .failed(playerError)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didReceiveError: playerError)
            }
            return
        }
        startDecoding()
        startTimeUpdates()
    }

    // MARK: - Pause

    public func pause() {
        guard state == .playing || state == .buffering else { return }
        playWhenReady = false
        renderer.pause()
        if isNetworkMode {
            pushSource?.suspend()
        }
        state = .paused
        stopTimeUpdates()
    }

    // MARK: - Stop

    public func stop() {
        // Pull-mode cleanup
        shouldStopDecoding = true
        bufferQueue.flush()
        stopTimeUpdates()
        renderer.stop()

        decoder?.close()
        decoder = nil
        source?.close()
        source = nil

        // Push-mode cleanup
        pushSource?.close()
        pushSource = nil
        streamDecoder?.close()
        streamDecoder = nil

        currentURL = nil
        currentTime = 0
        duration = 0
        playbackBaseTime = 0
        playWhenReady = false
        isNetworkMode = false
        streamEndReached = false
        bufferingReason = nil
        networkBufferedDuration = 0

        state = .idle
    }

    // MARK: - Seek

    /// Seek to a specific time in seconds.
    public func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        // 网络流 duration 尚未确定时，无法 clamp 也无法计算字节偏移，直接失败
        guard duration > 0 || state == .idle else {
            VILogger.debug("[VIAudioPlayer] seek: duration unknown, ignoring")
            completion?(false)
            return
        }
        let targetTime = duration > 0 ? max(0, min(time, duration)) : max(0, time)

        if isNetworkMode {
            seekNetwork(to: targetTime, completion: completion)
        } else {
            seekLocal(to: targetTime, completion: completion)
        }
    }

    /// Seek by progress (0.0 – 1.0).
    public func seek(progress: Double, completion: ((Bool) -> Void)? = nil) {
        let clamped = max(0, min(1, progress))
        seek(to: duration * clamped, completion: completion)
    }

    // MARK: - Seek: Local (Pull)

    func seekLocal(to time: TimeInterval, completion: ((Bool) -> Void)?) {
        guard decoder != nil else {
            completion?(false)
            return
        }

        let thisGeneration: Int = stateQueue.sync {
            isSeeking = true
            seekGeneration += 1
            return seekGeneration
        }

        let wasPlaying = isPlaying

        stopDecoding()
        stopTimeUpdates()
        renderer.stop()

        decodeQueue.async { [weak self] in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisGeneration != self.seekGeneration }
            if stale {
                completion?(false)
                return
            }

            guard let decoder = self.decoder else {
                self.stateQueue.sync { self.isSeeking = false }
                completion?(false)
                return
            }

            do {
                try decoder.seek(to: time)
                self.playbackBaseTime = time
                self.currentTime = time

                if let fmt = self.decoder?.outputFormat {
                    try self.renderer.prepare(format: fmt)
                }

                let stillCurrent: Bool = self.stateQueue.sync {
                    let current = thisGeneration == self.seekGeneration
                    self.isSeeking = false
                    return current
                }

                guard stillCurrent else {
                    completion?(false)
                    return
                }

                if wasPlaying {
                    DispatchQueue.main.async {
                        guard self.state == .playing || self.state == .paused
                                || self.state == .buffering else { return }
                        self.state = .playing
                        self.renderer.rate = self.desiredRate
                        do {
                            try self.renderer.play()
                        } catch {
                            let playerError = VIPlayerError.renderingFailed(error)
                            self.state = .failed(playerError)
                            self.delegate?.player(self, didReceiveError: playerError)
                            return
                        }
                        self.startDecoding()
                        self.startTimeUpdates()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.player(self, didUpdateTime: time, duration: self.duration)
                    }
                }
                completion?(true)
            } catch {
                self.stateQueue.sync { self.isSeeking = false }
                let playerError = VIPlayerError.seekFailed(error)
                self.state = .failed(playerError)
                DispatchQueue.main.async {
                    self.delegate?.player(self, didReceiveError: playerError)
                }
                completion?(false)
            }
        }
    }

    // MARK: - Seek: Network (Push)

    func seekNetwork(to time: TimeInterval, completion: ((Bool) -> Void)?) {
        guard let sd = streamDecoder, let ps = pushSource else {
            completion?(false)
            return
        }

        let wasPlaying = isPlaying || playWhenReady

        stateQueue.sync {
            seekGeneration += 1
            networkBufferedDuration = 0
        }

        renderer.stop()
        bufferQueue.reset()
        streamEndReached = false
        bufferingReason = .afterSeek

        let byteOffset = sd.seekOffset(for: time) ?? 0

        // Reset stream decoder for a discontinuity
        sd.resetForSeek()

        if let cl = ps.contentLength {
            sd.contentLength = cl
        }

        playbackBaseTime = time
        currentTime = time

        if wasPlaying {
            playWhenReady = true
            state = .buffering
        } else {
            state = .buffering
        }

        // Seek the push source to the byte offset
        ps.seek(to: byteOffset)

        // Prepare renderer if format is already known (don't play yet, checkBufferingToPlaying handles transition)
        if let fmt = sd.outputFormat {
            try? renderer.prepare(format: fmt)
            renderer.rate = desiredRate
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.player(self, didUpdateTime: time, duration: self.duration)
        }
        completion?(true)
    }

    // MARK: - Cache management (forwarded)

    /// Query the cache status of a URL (none / partial / complete).
    public func cacheStatus(for url: URL) -> VICacheStatus {
        downloader.cacheStatus(for: url)
    }

    /// Returns the file URL if the resource is fully cached, otherwise nil.
    public func completeCacheURL(for url: URL) -> URL? {
        downloader.completeCacheURL(for: url)
    }

    /// Returns the cache directory for the given URL.
    /// Each URL maps to its own subdirectory under `cacheDirectory`.
    /// Returns nil if the URL has never been cached.
    public func cachePath(for url: URL) -> URL? {
        let key = configuration.downloaderConfiguration.cacheKey(for: url)
        let dir = cacheDirectory.appendingPathComponent(key, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Remove cached data for a specific URL.
    public func removeCache(for url: URL) {
        downloader.removeCache(for: url)
    }

    /// Remove all cached audio data.
    public func removeAllCache() {
        downloader.removeAllCache()
    }

    /// The root directory where all cached audio files are stored.
    public var cacheDirectory: URL {
        configuration.downloaderConfiguration.cacheDirectory
    }

}
