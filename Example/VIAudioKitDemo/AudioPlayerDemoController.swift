import UIKit
import VIAudioKit
import QuartzCore

#if canImport(VIAudioFFmpeg)
import VIAudioFFmpeg
#endif

// MARK: - Audio Item

struct AudioItem {
    let title: String
    let url: URL
    let isLocal: Bool
}

// MARK: - Controller

final class AudioPlayerDemoController: UIViewController {

    // ============================================================
    // MARK: Audio items — local files auto-discovered, add remote URLs below
    // ============================================================
    private static let supportedExtensions = ["mp3", "aac", "m4a", "mp4", "flac", "alac", "wav", "aiff", "caf", "ogg", "wma", "opus"]

    private lazy var audioItems: [AudioItem] = {
        var items: [AudioItem] = []

        for ext in Self.supportedExtensions {
            guard let paths = Bundle.main.paths(forResourcesOfType: ext, inDirectory: nil) as [String]? else { continue }
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let name = url.deletingPathExtension().lastPathComponent
                items.append(AudioItem(title: "[\(ext.uppercased())] \(name)", url: url, isLocal: true))
            }
        }
        items.sort { $0.title < $1.title }

        // --- Remote URLs: add your test URLs here ---
        // 这两个远程地址有过期时间，播放不了就换地址
        items.append(AudioItem(
            title: "童话镇-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E7%AB%A5%E8%AF%9D%E9%95%87.flac")!,
            isLocal: false
        ))
        
        items.append(AudioItem(
            title: "不煽情-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E4%B8%8D%E7%85%BD%E6%83%85%E5%8E%9F%E7%89%88%E4%BC%B4%E5%A5%8F.mp3")!,
            isLocal: false
        ))

        // FFmpeg test URLs
        items.append(AudioItem(
            title: "天空之城aac-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E5%A4%A9%E7%A9%BA%E4%B9%8B%E5%9F%8E.aac")!,
            isLocal: false
        ))
        
        items.append(AudioItem(
            title: "天空之城ogg-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E5%A4%A9%E7%A9%BA%E4%B9%8B%E5%9F%8E.ogg")!,
            isLocal: false
        ))
        
        items.append(AudioItem(
            title: "天空之城opus-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E5%A4%A9%E7%A9%BA%E4%B9%8B%E5%9F%8E.opus")!,
            isLocal: false
        ))
        
        items.append(AudioItem(
            title: "天空之城wma-url",
            url: URL(string: "https://leafli.oss-cn-shanghai.aliyuncs.com/%E9%9F%B3%E9%A2%91/%E5%A4%A9%E7%A9%BA%E4%B9%8B%E5%9F%8E.wma")!,
            isLocal: false
        ))
        
        items.append(AudioItem(
            title: "华尔 wav-url",
            url: URL(string: "http://cdn9002.iflyos.cn/whitenoise/09bead66f707b14fcf54b9e813a9056c.wav")!,
            isLocal: false
        ))

        // --- Mix test (VIMixingDecoder) ---
        if items.count >= 2 {
            // Find two local files to mix
            let localItems = items.filter { $0.isLocal }
            if localItems.count >= 2 {
                let url1 = localItems[0].url.absoluteString
                let url2 = localItems[1].url.absoluteString
                if let jsonData = try? JSONSerialization.data(withJSONObject: [url1, url2], options: []),
                   let stringData = String(data: jsonData, encoding: .utf8) {
                    
                    let mixFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("mixed_test.vimix")
                    try? stringData.write(to: mixFileURL, atomically: true, encoding: .utf8)
                    
                    items.insert(AudioItem(
                        title: "[MIX] \(localItems[0].url.lastPathComponent) + \(localItems[1].url.lastPathComponent)",
                        url: mixFileURL,
                        isLocal: true
                    ), at: 0)
                }
            }
        }

        return items
    }()

    // MARK: - Player

    private let player: VIAudioPlayer = {
        let p = VIAudioPlayer()
        p.decoderTypes.append(VIFFmpegDecoder.self)
        p.streamDecoderTypes.append(VIFFmpegStreamDecoder.self)
        return p
    }()
    private var currentIndex: Int = -1
    private var lastCacheUpdateTime: Date?
    /// Bumps when switching tracks so stale `updateCacheInfo()` completions cannot overwrite the new row’s UI.
    private var cacheInfoGeneration: Int = 0

    // MARK: - UI Components

    private let tableView = UITableView(frame: .zero, style: .plain)

    private let artworkView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.systemGray5
        v.layer.cornerRadius = 16
        return v
    }()
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 18, weight: .semibold)
        l.textAlignment = .center
        l.text = "No Audio Selected"
        return l
    }()
    private let stateLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.text = "Idle"
        return l
    }()

    private let bufferingIndicator: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .medium)
        v.hidesWhenStopped = true
        return v
    }()

    // Progress
    private let progressSlider: UISlider = {
        let s = UISlider()
        s.minimumValue = 0
        s.maximumValue = 1
        s.value = 0
        s.minimumTrackTintColor = .systemBlue
        return s
    }()
    private let currentTimeLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.text = "00:00"
        return l
    }()
    private let durationLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.text = "00:00"
        l.textAlignment = .right
        return l
    }()

    private let bufferProgressView: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .default)
        p.trackTintColor = .clear
        p.progressTintColor = UIColor.systemBlue.withAlphaComponent(0.25)
        p.progress = 0
        return p
    }()

    // Controls
    private let playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        b.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        b.tintColor = .white
        b.backgroundColor = .systemBlue
        b.layer.cornerRadius = 22
        b.layer.masksToBounds = true
        // Ensure the button can be interacted with smoothly even when rapidly tapped
        b.isExclusiveTouch = true
        b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return b
    }()
    private let stopButton: UIButton = {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        b.setImage(UIImage(systemName: "stop.circle", withConfiguration: config), for: .normal)
        b.tintColor = .systemGray
        return b
    }()
    private let backwardButton: UIButton = {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        b.setImage(UIImage(systemName: "gobackward.15", withConfiguration: config), for: .normal)
        return b
    }()
    private let forwardButton: UIButton = {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        b.setImage(UIImage(systemName: "goforward.15", withConfiguration: config), for: .normal)
        return b
    }()

    // Rate
    private let rateSegmented: UISegmentedControl = {
        let s = UISegmentedControl(items: ["0.5x", "1.0x", "1.5x", "2.0x"])
        s.selectedSegmentIndex = 1
        return s
    }()

    // Cache info
    private let cacheLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .tertiaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.text = "Cache: —"
        return l
    }()

    // Toolbar buttons
    private let clearCacheButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Clear Cache", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        b.setTitleColor(.systemRed, for: .normal)
        return b
    }()

    private let cachePathButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Cache Path", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        return b
    }()

    private var isScrubbing = false
    private let cacheInfoQueue = DispatchQueue(label: "com.viaudiokit.demo.cacheinfo", qos: .utility)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VIAudioKit Demo"
        view.backgroundColor = .systemBackground
        player.delegate = self
        setupUI()
        setupActions()

        if audioItems.isEmpty {
            stateLabel.text = "Add audio items in AudioPlayerDemoController.audioItems"
        }
    }

    // MARK: - Setup UI

    private func setupUI() {
        view.addSubview(artworkView)
        artworkView.addSubview(titleLabel)
        artworkView.addSubview(stateLabel)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(bufferProgressView)
        view.addSubview(progressSlider)
        view.addSubview(currentTimeLabel)
        view.addSubview(durationLabel)
        bufferProgressView.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        let controlStack = UIStackView(arrangedSubviews: [
            backwardButton, playPauseButton, forwardButton, stopButton
        ])
        controlStack.axis = .horizontal
        controlStack.spacing = 28
        controlStack.alignment = .center
        view.addSubview(controlStack)
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.addSubview(bufferingIndicator)
        bufferingIndicator.translatesAutoresizingMaskIntoConstraints = false
        // Let touches pass through the indicator to the button
        bufferingIndicator.isUserInteractionEnabled = false

        view.addSubview(rateSegmented)
        rateSegmented.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(cacheLabel)
        cacheLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbarStack = UIStackView(arrangedSubviews: [clearCacheButton, cachePathButton])
        toolbarStack.axis = .horizontal
        toolbarStack.spacing = 20
        toolbarStack.alignment = .center
        view.addSubview(toolbarStack)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let g = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            artworkView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            artworkView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            artworkView.heightAnchor.constraint(equalToConstant: 80),

            titleLabel.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: -16),

            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            stateLabel.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),

            bufferingIndicator.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
            bufferingIndicator.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            bufferProgressView.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 20),
            bufferProgressView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 58),
            bufferProgressView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -58),
            bufferProgressView.heightAnchor.constraint(equalToConstant: 4),

            progressSlider.centerYAnchor.constraint(equalTo: bufferProgressView.centerYAnchor),
            progressSlider.leadingAnchor.constraint(equalTo: bufferProgressView.leadingAnchor),
            progressSlider.trailingAnchor.constraint(equalTo: bufferProgressView.trailingAnchor),

            currentTimeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            currentTimeLabel.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor),

            durationLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),

            controlStack.topAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor, constant: 16),
            controlStack.centerXAnchor.constraint(equalTo: g.centerXAnchor),

            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            rateSegmented.topAnchor.constraint(equalTo: controlStack.bottomAnchor, constant: 16),
            rateSegmented.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            rateSegmented.widthAnchor.constraint(equalToConstant: 260),

            cacheLabel.topAnchor.constraint(equalTo: rateSegmented.bottomAnchor, constant: 10),
            cacheLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            cacheLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),

            toolbarStack.topAnchor.constraint(equalTo: cacheLabel.bottomAnchor, constant: 8),
            toolbarStack.centerXAnchor.constraint(equalTo: g.centerXAnchor),

            tableView.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
    }

    // MARK: - Actions

    private func setupActions() {
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        backwardButton.addTarget(self, action: #selector(seekBackward), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(seekForward), for: .touchUpInside)
        rateSegmented.addTarget(self, action: #selector(rateChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)
        cachePathButton.addTarget(self, action: #selector(cachePathTapped), for: .touchUpInside)
    }

    @objc private func togglePlayPause() {
        switch player.state {
        case .playing:
            player.pause()
        case .ready, .paused, .buffering, .preparing:
            if player.playWhenReady {
                player.pause()
            } else {
                player.play()
            }
        default:
            if currentIndex >= 0 {
                loadAndPlay(index: currentIndex)
            }
        }
        // Force an immediate UI update based on the current player state
        updatePlayPauseIcon(state: player.state)
    }

    @objc private func stopTapped() {
        player.stop()
        progressSlider.value = 0
        currentTimeLabel.text = "00:00"
        updatePlayPauseIcon(state: .idle)
    }

    @objc private func seekBackward() {
        let target = max(0, player.currentTime - 15)
        player.seek(to: target)
    }

    @objc private func seekForward() {
        let target = min(player.duration, player.currentTime + 15)
        player.seek(to: target)
    }

    @objc private func rateChanged() {
        let rates: [Float] = [0.5, 1.0, 1.5, 2.0]
        player.rate = rates[rateSegmented.selectedSegmentIndex]
    }

    @objc private func sliderTouchDown() {
        isScrubbing = true
    }

    @objc private func sliderValueChanged() {
        let time = Double(progressSlider.value) * player.duration
        currentTimeLabel.text = formatTime(time)
    }

    @objc private func sliderTouchUp() {
        let progress = Double(progressSlider.value)
        player.seek(progress: progress) { [weak self] _ in
            self?.isScrubbing = false
        }
    }

    @objc private func clearCacheTapped() {
        let alert = UIAlertController(
            title: "Clear Cache",
            message: "Remove all downloaded audio cache? This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.player.stop()
            self.player.removeAllCache()
            self.cacheLabel.text = "Cache: cleared"
            self.bufferProgressView.progress = 0
        })
        present(alert, animated: true)
    }

    @objc private func cachePathTapped() {
        let path = player.cacheDirectory.path
        let alert = UIAlertController(
            title: "Cache Directory",
            message: path,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = path
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func loadAndPlay(index: Int) {
        guard index < audioItems.count else { return }
        
        let wasPlaying = player.isPlaying
        
        currentIndex = index
        cacheInfoGeneration += 1
        lastCacheUpdateTime = nil

        let item = audioItems[index]
        titleLabel.text = item.title
        bufferProgressView.progress = 0
        progressSlider.value = 0
        currentTimeLabel.text = "00:00"
        durationLabel.text = "00:00"
        if item.isLocal {
            cacheLabel.text = "Cache: local file"
        } else {
            cacheLabel.text = "Cache: …"
        }
        
        player.load(url: item.url)
        updateCacheInfo()

        if wasPlaying {
            player.play()
        }
    }

    private func updatePlayPauseIcon(state: VIPlayerState) {
        let isPlaying = state == .playing
        var name: String? = isPlaying ? "pause.fill" : "play.fill"
        let isBufferForPlay = (state == .buffering || state == .preparing) && player.playWhenReady
        if isBufferForPlay {
            name = nil
        }
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        var image: UIImage?
        if let name = name {
            image = UIImage(systemName: name, withConfiguration: config)
        }
        
        if isBufferForPlay {
            // Keep the icon visible but dim it slightly, and show the spinner over it
            playPauseButton.setImage(image, for: .normal)
            bufferingIndicator.startAnimating()
        } else {
            playPauseButton.setImage(image, for: .normal)
            playPauseButton.alpha = 1.0
            bufferingIndicator.stopAnimating()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Keeps time labels + slider aligned with `VIAudioPlayer` when state changes (e.g. new track loads).
    private func syncProgressLabelsFromPlayer(_ player: VIAudioPlayer) {
        currentTimeLabel.text = formatTime(player.currentTime)
        durationLabel.text = formatTime(player.duration)
        if player.duration > 0 {
            progressSlider.value = Float(player.currentTime / player.duration)
        } else {
            progressSlider.value = 0
        }
    }

    private func updateCacheInfo() {
        guard currentIndex >= 0, currentIndex < audioItems.count else { return }
        let item = audioItems[currentIndex]
        let generation = cacheInfoGeneration
        cacheInfoQueue.async { [weak self] in
            guard let self else { return }
            if item.isLocal {
                DispatchQueue.main.async {
                    guard generation == self.cacheInfoGeneration else { return }
                    self.cacheLabel.text = "Cache: local file"
                }
                return
            }

            let status = self.player.cacheStatus(for: item.url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.cacheInfoGeneration else { return }
                switch status {
                case .none:
                    self.cacheLabel.text = "Cache: none"
                case .partial(let downloaded, let total, _):
                    let pct = total > 0 ? Int(Double(downloaded) / Double(total) * 100) : 0
                    let dlMB = String(format: "%.1f", Double(downloaded) / 1_048_576)
                    let totalMB = String(format: "%.1f", Double(total) / 1_048_576)
                    self.cacheLabel.text = "Cache: \(dlMB)MB / \(totalMB)MB (\(pct)%)"
                    self.bufferProgressView.setProgress(Float(pct) / 100.0, animated: true)
                case .complete:
                    self.cacheLabel.text = "Cache: complete"
                    self.bufferProgressView.setProgress(1.0, animated: true)
                }
            }
        }
    }

    private func cacheSizeString() -> String {
        let path = player.cacheDirectory.path
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return "0 B" }
        var totalSize: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

// MARK: - VIAudioPlayerDelegate

extension AudioPlayerDemoController: VIAudioPlayerDelegate {

    func player(_ player: VIAudioPlayer, didChangeState state: VIPlayerState) {
        updatePlayPauseIcon(state: state)
        switch state {
        case .idle:
            stateLabel.text = "Idle"
        case .preparing:
            stateLabel.text = "Preparing..."
            syncProgressLabelsFromPlayer(player)
        case .ready:
            stateLabel.text = "Ready"
            syncProgressLabelsFromPlayer(player)
        case .playing:
            stateLabel.text = "Playing"
        case .paused:
            stateLabel.text = "Paused"
        case .buffering:
            stateLabel.text = "Buffering"
            syncProgressLabelsFromPlayer(player)
        case .finished:
            stateLabel.text = "Finished"
        case .failed(let error):
            stateLabel.text = "Error"
            showErrorAlert(error)
        }
        // Keep state transition lightweight on main thread; cache info refreshes asynchronously.
    }

    func player(_ player: VIAudioPlayer, didUpdateTime currentTime: TimeInterval, duration: TimeInterval) {
        guard !isScrubbing else { return }
        currentTimeLabel.text = formatTime(currentTime)
        durationLabel.text = formatTime(duration)
        if duration > 0 {
            progressSlider.value = Float(currentTime / duration)
        }
        
        throttledUpdateCacheInfo()
    }

    func player(_ player: VIAudioPlayer, didUpdateBuffer state: VIBufferState) {
        // UI relies on updateCacheInfo() to update bufferProgressView with overall download progress,
        // so we don't overwrite it with the 0-2s playback buffer state here.
        // However, we do want to poll cache progress while downloading/buffering (even if paused/not playing).
        throttledUpdateCacheInfo()
    }

    private func throttledUpdateCacheInfo() {
        let now = Date()
        if let last = lastCacheUpdateTime, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastCacheUpdateTime = now
        updateCacheInfo()
    }

    func player(_ player: VIAudioPlayer, didReceiveError error: VIPlayerError) {
        showErrorAlert(error)
    }

    private func showErrorAlert(_ error: VIPlayerError) {
        let show = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "Playback Error",
                                          message: "\(error)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
        if presentedViewController != nil {
            dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }
}

// MARK: - UITableView DataSource/Delegate

extension AudioPlayerDemoController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        audioItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = audioItems[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = item.isLocal ? "Local File" : item.url.host ?? ""
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)
        cell.contentConfiguration = content
        cell.accessoryType = indexPath.row == currentIndex ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Audio List"
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        loadAndPlay(index: indexPath.row)
        tableView.reloadData()
    }
}
