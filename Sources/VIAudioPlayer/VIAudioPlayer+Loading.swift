import Foundation
import AVFoundation
#if !COCOAPODS
import VIAudioDownloader
import VIAudioDecoder
#endif

// MARK: - 资源加载

extension VIAudioPlayer {

    // MARK: - Load

    /// Load an audio resource. Accepts both local file URLs and remote HTTP URLs.
    public func load(url: URL) {
        stop()
        currentURL = url
        playbackBaseTime = 0
        playWhenReady = false
        streamEndReached = false
        networkBufferedDuration = 0

        let thisLoad: Int = stateQueue.sync {
            loadGeneration += 1
            return loadGeneration
        }

        state = .preparing

        // Reset time/duration on the main queue so UI can clear the previous track immediately
        // (stop() zeroes values but delegate was not notified).
        let t = currentTime
        let d = duration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.player(self, didUpdateTime: t, duration: d)
        }

        VILogger.debug("[VIAudioPlayer] load: \(url.lastPathComponent) isFile=\(url.isFileURL)")

        if url.isFileURL {
            isNetworkMode = false
            loadLocalFile(url: url, extensionHint: nil, thisLoad: thisLoad)
        } else {
            if let cachedURL = downloader.completeCacheURL(for: url) {
                // 诊断日志：验证缓存文件
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size] as? Int64) ?? -1
                VILogger.debug("[VIAudioPlayer] load: fully cached, file=\(cachedURL.lastPathComponent) diskSize=\(fileSize)")
                isNetworkMode = false
                let originalExt = url.pathExtension.lowercased()
                loadLocalFile(url: cachedURL, extensionHint: originalExt, thisLoad: thisLoad, fallbackURL: url)
            } else {
                isNetworkMode = true
                loadNetworkFile(url: url, thisLoad: thisLoad)
            }
        }
    }

    // MARK: - Load: Local (Pull)

    /// - Parameter extensionHint: Override file extension (used when loading from cache
    ///   where the on-disk filename is a hash, not the original name).
    /// - Parameter fallbackURL: 缓存文件本地加载失败时，回退到 push 模式使用的原始网络 URL。
    func loadLocalFile(url: URL, extensionHint: String?, thisLoad: Int, fallbackURL: URL? = nil) {
        decodeQueue.async { [weak self] in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else {
                VILogger.debug("[VIAudioPlayer] load: stale (generation \(thisLoad)), skipping")
                return
            }

            do {
                let source = try VILocalFileSource(fileURL: url, extensionOverride: extensionHint)
                self.source = source

                let ext = (extensionHint?.isEmpty == false) ? extensionHint! : source.fileExtension
                VILogger.debug("[VIAudioPlayer] load: ext=\(ext) size=\(source.contentLength ?? -1)")

                // 优先查找映射的解码器
                let decoderType: VIAudioDecoding.Type
                if let mappedType = self.configuration.decoderMapping[ext] {
                    VILogger.debug("[VIAudioPlayer] load: using mapped decoder for \(ext)")
                    decoderType = mappedType
                } else {
                    // 回退到顺序匹配
                    guard let type = self.decoderTypes.first(where: {
                        $0.supportedExtensions.contains(ext)
                    }) else {
                        throw VIPlayerError.decoderCreationFailed(
                            VIDecoderError.unsupportedFormat(ext)
                        )
                    }
                    decoderType = type
                }

                let decoder = try decoderType.init(source: source)

                let staleAfterDecode: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
                if staleAfterDecode {
                    decoder.close()
                    VILogger.debug("[VIAudioPlayer] load: stale after decode init, skipping")
                    return
                }

                self.decoder = decoder
                self.duration = decoder.duration

                VILogger.debug("[VIAudioPlayer] load: decoder ready, duration=\(String(format: "%.2f", decoder.duration))s")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.player(self, didUpdateTime: self.currentTime, duration: self.duration)
                }
                try self.renderer.prepare(format: decoder.outputFormat)
                VILogger.debug("[VIAudioPlayer] load: renderer prepared, setting state=ready")
                self.state = .ready
                if self.playWhenReady {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let stillCurrent = self.stateQueue.sync { thisLoad == self.loadGeneration }
                        guard stillCurrent else { return }
                        self.play()
                    }
                }
            } catch {
                // 缓存文件本地解码失败（可能文件尾部有脏数据，Apple 的解析器严格拒绝），
                // 回退到 push 模式，流式解析器（AudioFileStream）更宽容。
                if let networkURL = fallbackURL {
                    VILogger.debug("[VIAudioPlayer] load: local decode failed (\(error)), falling back to push mode")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let stillCurrent = self.stateQueue.sync { thisLoad == self.loadGeneration }
                        guard stillCurrent else { return }
                        self.isNetworkMode = true
                        self.loadNetworkFile(url: networkURL, thisLoad: thisLoad)
                    }
                    return
                }

                let stillCurrent: Bool = self.stateQueue.sync { thisLoad == self.loadGeneration }
                guard stillCurrent else { return }

                VILogger.debug("[VIAudioPlayer] load failed: \(error)")
                let playerError = self.wrapError(error)
                self.state = .failed(playerError)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.player(self, didReceiveError: playerError)
                }
            }
        }
    }

    // MARK: - Load: Network (Push)

    func loadNetworkFile(url: URL, thisLoad: Int) {
        let ext = url.pathExtension.lowercased()
        self.networkFileExt = ext

        let ps = VIPushAudioSource(
            url: url,
            cacheManager: downloader.cacheManager,
            configuration: configuration.downloaderConfiguration
        )

        // 优先查找映射的流解码器
        let sdType: VIStreamDecoding.Type
        if let mappedType = configuration.streamDecoderMapping[ext] {
            VILogger.debug("[VIAudioPlayer] load: using mapped stream decoder for \(ext)")
            sdType = mappedType
        } else {
            // 回退到顺序匹配
            sdType = streamDecoderTypes.first(where: {
                $0.supportedExtensions.contains(ext)
            }) ?? VIStreamDecoder.self
        }

        let sd = sdType.init()
        sd.framesPerBuffer = configuration.framesPerBuffer
        if let extSd = sd as? VIStreamDecodingWithExtension {
            extSd.fileExtension = ext
        }

        self.pushSource = ps
        self.streamDecoder = sd

        state = .buffering
        bufferingReason = .initialLoad
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyBufferState()
        }

        // Wire push source → stream decoder → buffer queue → renderer
        ps.onContentLengthAvailable = { [weak self, weak sd] length in
            guard let self, let sd else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            sd.contentLength = length
            // Native stream decoder: recomputes duration from Content-Length + bitrate.
            // FFmpeg push decoder (VIFFmpegStreamDecoder): do NOT call updateDuration() here — it takes
            // `stateLock` while the decode thread holds that same lock during avformat_open_input /
            // avformat_find_stream_info (blocking on custom IO). The URL session queue often delivers
            // this callback before the first data chunk, so we deadlock before feed() runs and OGG/WMA
            // never finishes probing. Duration is updated inside the FFmpeg decoder once stream info exists.
            if let nativeSD = sd as? VIStreamDecoder {
                nativeSD.updateDuration()
            }
            if sd.duration > 0 {
                self.duration = sd.duration
                VILogger.debug("[VIAudioPlayer] duration updated from content length: \(String(format: "%.2f", sd.duration))s")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.player(self, didUpdateTime: self.currentTime, duration: self.duration)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notifyBufferState()
            }
        }

        var dataChunkCount = 0
        ps.onDataReceived = { [weak self, weak sd] data in
            guard let self, let sd else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            dataChunkCount += 1
            if dataChunkCount <= 5 || dataChunkCount % 50 == 0 {
                VILogger.debug("[VIAudioPlayer] onDataReceived #\(dataChunkCount): \(data.count) bytes, total fed to decoder=\(sd.totalBytesReceived + Int64(data.count))")
            }
            sd.feed(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notifyBufferState()
            }
        }

        sd.onOutputFormatReady = { [weak self] format, dur in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            if dur > 0 {
                self.duration = dur
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.player(self, didUpdateTime: self.currentTime, duration: self.duration)
            }
            do {
                try self.renderer.prepare(format: format)
            } catch {
                VILogger.debug("[VIAudioPlayer] renderer prepare failed: \(error)")
            }
            VILogger.debug("[VIAudioPlayer] load(network): format ready, duration=\(String(format: "%.2f", self.duration))s")
        }

        var bufferReadyCount = 0
        sd.onBufferReady = { [weak self] buffer in
            guard let self else { return }

            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }

            let rate = buffer.format.sampleRate
            let bufDur = rate > 0 ? Double(buffer.frameLength) / rate : 0
            let accumulated: TimeInterval = self.stateQueue.sync {
                self.networkBufferedDuration += bufDur
                return self.networkBufferedDuration
            }

            bufferReadyCount += 1
            if bufferReadyCount <= 5 || bufferReadyCount % 50 == 0 {
                VILogger.debug("[VIAudioPlayer] onBufferReady #\(bufferReadyCount): frames=\(buffer.frameLength) state=\(self.state) accumulated=\(String(format: "%.2f", accumulated))s")
            }

            if self.state == .playing {
                self.renderer.scheduleBuffer(buffer)
            } else {
                if !self.bufferQueue.tryEnqueue(buffer) {
                    self.renderer.scheduleBuffer(buffer)
                }
            }
        }

        sd.onEndOfStream = { [weak self] in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            self.streamEndReached = true
            self.feedRenderer()
            self.checkStreamFinished()
        }

        sd.onError = { [weak self] error in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] stream decoder error: \(error)")
            let playerError = VIPlayerError.decoderCreationFailed(error)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = .failed(playerError)
                self.delegate?.player(self, didReceiveError: playerError)
            }
        }

        ps.onWaitingForNetworkChanged = { [weak self] waiting in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            if waiting {
                VILogger.debug("[VIAudioPlayer] waiting for network…")
            } else {
                VILogger.debug("[VIAudioPlayer] network recovered")
            }
        }

        ps.onEndOfFile = { [weak self] in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] push source: end of file")
            self.streamEndReached = true
            self.streamDecoder?.flush()
            self.feedRenderer()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkBufferingToPlaying()
                self.checkStreamFinished()
                self.notifyBufferState()
            }
        }

        ps.onError = { [weak self] error in
            guard let self else { return }
            let stale: Bool = self.stateQueue.sync { thisLoad != self.loadGeneration }
            guard !stale else { return }
            VILogger.debug("[VIAudioPlayer] push source fatal error: \(error)")
            let playerError = VIPlayerError.networkError(error)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = .failed(playerError)
                self.delegate?.player(self, didReceiveError: playerError)
            }
        }

        let hint = VIStreamDecoder.fileTypeHint(for: ext)
        do {
            try sd.open(fileTypeHint: hint)
        } catch {
            VILogger.debug("[VIAudioPlayer] load: stream decoder open failed: \(error)")
            let playerError = VIPlayerError.decoderCreationFailed(error)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = .failed(playerError)
                self.delegate?.player(self, didReceiveError: playerError)
            }
            return
        }

        // Start streaming and periodic buffer checks
        ps.start()
        startTimeUpdates()
    }
}
