# VIAudioKit

跨平台（iOS / macOS）音频播放框架，基于 `AVAudioEngine` 渲染，支持本地与网络音频、分片下载缓存、自定义解码器、变速播放以及完善的缓冲状态管理。

## 特性

- **多平台**：iOS 15+ / macOS 12+
- **本地 + 网络**：自动识别 `file://` 与 `http(s)://`，无需手动区分
- **多格式**：MP3、AAC、M4A、FLAC、WAV、AIFF、CAF 等（基于 Apple AudioToolbox），可通过 `VIAudioDecoding` 协议扩展自定义解码器
- **分片下载与缓存**：HTTP Range 请求分片下载，LRU 缓存淘汰，支持 seek 时按需下载，同一音频不同 URL 可映射为相同缓存键
- **变速播放**：通过 `AVAudioUnitTimePitch` 实现 0.5x – 2.0x 变速
- **缓冲状态机**：可配置的缓冲阈值（初始播放 / seek 后 / 欠载恢复），自动网络恢复重试
- **双集成方式**：Swift Package Manager 和 CocoaPods 均支持

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    VIAudioPlayer                     │
│  (状态机 · 缓冲控制 · 对外 API · Delegate 回调)       │
├───────────────────────┬─────────────────────────────┤
│   本地路径 (Pull)      │     网络路径 (Push)          │
│                       │                             │
│  VILocalFileSource    │  VIPushAudioSource           │
│       ↓               │  (NWPathMonitor · 自动重试)  │
│  VINativeDecoder      │       ↓                     │
│  (ExtAudioFile)       │  VIStreamDecoder             │
│       ↓               │  (AudioFileStream +          │
│  VIAudioBufferQueue   │   AudioConverter)            │
│       ↓               │       ↓                     │
├───────────────────────┴─────────────────────────────┤
│                   VIAudioRenderer                    │
│  (AVAudioEngine · AVAudioPlayerNode · TimePitch)     │
├─────────────────────────────────────────────────────┤
│                  VIAudioDownloader                   │
│  (VIChunkedDownloader · VICacheManager · LRU 缓存)   │
└─────────────────────────────────────────────────────┘
```

### 模块说明

| 模块 | 路径 | 职责 |
|---|---|---|
| **VIAudioPlayer** | `Sources/VIAudioPlayer/` | 播放器核心：状态机、缓冲控制、时间进度、对外 API |
| **VIAudioDecoder** | `Sources/VIAudioDecoder/` | 解码层：`VINativeDecoder`（本地 Pull）、`VIStreamDecoder`（网络 Push）、`VIPushAudioSource`（网络数据源） |
| **VIAudioDownloader** | `Sources/VIAudioDownloader/` | 下载缓存层：分片下载、Range 请求、LRU 缓存管理，可独立使用 |

### 关键文件

```
Sources/
├── VIAudioPlayer/
│   ├── VIAudioPlayer.swift        # 播放器主类，对外 API
│   ├── VIAudioRenderer.swift      # AVAudioEngine 封装
│   ├── VIAudioBufferQueue.swift   # 线程安全 PCM Buffer 队列
│   ├── VIPlayerConfiguration.swift # 播放器配置
│   └── VIPlayerState.swift        # 状态枚举、错误类型
├── VIAudioDecoder/
│   ├── VIAudioDecoding.swift      # 解码器协议（可扩展）
│   ├── VINativeDecoder.swift      # 本地文件解码器（ExtAudioFile）
│   ├── VIStreamDecoder.swift      # 流式解码器（AudioFileStream + AudioConverter）
│   ├── VIPushAudioSource.swift    # 网络推送数据源（含网络恢复、重试）
│   ├── VIAudioSource.swift        # 数据源协议
│   └── VILocalFileSource.swift    # 本地文件数据源
└── VIAudioDownloader/
    ├── VIChunkedDownloader.swift   # 分片下载器
    ├── VICacheManager.swift        # 缓存索引管理
    ├── VICacheUnit.swift           # 单个音频的缓存单元
    ├── VICacheSegment.swift        # 缓存分片
    ├── VIDownloaderConfiguration.swift # 下载器配置
    ├── VIDownloadTask.swift        # 单次下载任务
    └── VIRangeRequest.swift        # HTTP Range 请求
```

## 集成

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/example/VIAudioKit.git", from: "0.1.0")
]

// Target
.target(dependencies: ["VIAudioPlayer"])
```

只引入 `VIAudioPlayer` 即可，它会自动依赖 `VIAudioDecoder` 和 `VIAudioDownloader`。

如果只需要下载缓存功能，可以单独引入 `VIAudioDownloader`。

### CocoaPods

```ruby
pod 'VIAudioKit', :path => '../VIAudioKit'
# 或远程
# pod 'VIAudioKit', '~> 0.1.0'
```

## 快速上手

### 基本播放

```swift
import VIAudioKit  // CocoaPods
// import VIAudioPlayer  // SPM

let player = VIAudioPlayer()
player.delegate = self

// 播放本地文件
player.load(url: Bundle.main.url(forResource: "song", withExtension: "flac")!)
player.play()

// 播放网络音频
player.load(url: URL(string: "https://example.com/song.mp3")!)
player.play()
```

### Delegate 回调

```swift
extension ViewController: VIAudioPlayerDelegate {
    func player(_ player: VIAudioPlayer, didChangeState state: VIPlayerState) {
        switch state {
        case .idle:       print("空闲")
        case .preparing:  print("准备中")
        case .ready:      print("就绪")
        case .playing:    print("播放中")
        case .paused:     print("已暂停")
        case .buffering:  print("缓冲中")
        case .finished:   print("播放完成")
        case .failed(let error): print("错误: \(error)")
        }
    }

    func player(_ player: VIAudioPlayer, didUpdateTime currentTime: TimeInterval, duration: TimeInterval) {
        // 更新进度条
    }

    func player(_ player: VIAudioPlayer, didReceiveError error: VIPlayerError) {
        // 处理错误
    }
}
```

### 控制播放

```swift
player.play()
player.pause()
player.stop()

// Seek（秒）
player.seek(to: 30.0)

// Seek（进度 0~1）
player.seek(progress: 0.5)

// 变速
player.rate = 1.5
```

### 缓存管理

```swift
// 查询缓存状态
let status = player.cacheStatus(for: url)
switch status {
case .none:
    print("未缓存")
case .partial(let downloaded, let total, _):
    print("已下载 \(downloaded)/\(total) 字节")
case .complete(let fileURL):
    print("已完整缓存: \(fileURL.path)")
}

// 获取指定 URL 的缓存目录
if let path = player.cachePath(for: url) {
    print("缓存路径: \(path.path)")
}

// 获取完整缓存文件路径
if let fileURL = player.completeCacheURL(for: url) {
    print("完整缓存文件: \(fileURL.path)")
}

// 删除单个 URL 的缓存
player.removeCache(for: url)

// 清空所有缓存
player.removeAllCache()

// 获取缓存根目录
print("缓存根目录: \(player.cacheDirectory.path)")
```

### 自定义配置

```swift
// 自定义下载配置
var dlConfig = VIDownloaderConfiguration(
    cacheDirectory: URL(fileURLWithPath: "/custom/cache/path"),  // 自定义缓存路径
    maxCacheSize: 1024 * 1024 * 1024,  // 1GB 缓存上限
    defaultChunkSize: 256 * 1024,       // 256KB 分片大小
    requestTimeoutInterval: 15          // 15s 超时
)

// 云存储 URL 去除签名参数（阿里云 OSS / AWS S3 等）
dlConfig.urlCanonicalizer = VIDownloaderConfiguration.stripQueryCanonicalizer

// 自定义播放器配置
let config = VIPlayerConfiguration(
    downloaderConfiguration: dlConfig,
    decodeBufferCount: 16,               // 解码缓冲区数量
    framesPerBuffer: 8192,               // 每个缓冲区帧数
    secondsRequiredToStartPlaying: 1.0,  // 起播缓冲时长
    secondsRequiredAfterSeek: 0.5,       // seek 后缓冲时长
    secondsRequiredAfterBufferUnderrun: 3.0  // 欠载恢复缓冲时长
)

let player = VIAudioPlayer(configuration: config)
```

### 独立使用下载模块

```swift
import VIAudioDownloader  // SPM
// import VIAudioKit       // CocoaPods

let downloader = VIChunkedDownloader()

// 下载完整文件
let task = downloader.download(url: url)

// 下载指定范围
let rangeTask = downloader.downloadRange(url: url, range: 0..<(512 * 1024))

// 查询缓存
let status = downloader.cacheStatus(for: url)

// 清理
downloader.removeCache(for: url)
downloader.removeAllCache()
```

### 自定义解码器

实现 `VIAudioDecoding` 协议即可扩展支持新格式：

```swift
final class MyOggDecoder: VIAudioDecoding {
    static var supportedExtensions: Set<String> { ["ogg"] }

    required init(source: VIAudioSource) throws {
        // 初始化解码器
    }

    var outputFormat: AVAudioFormat { /* PCM 输出格式 */ }
    var duration: TimeInterval { /* 总时长 */ }
    var currentTime: TimeInterval { /* 当前位置 */ }

    func decode(into buffer: AVAudioPCMBuffer) -> Int {
        // 解码填充 buffer，返回帧数
    }

    func seek(to time: TimeInterval) throws {
        // 跳转
    }

    func close() {
        // 释放资源
    }
}
```

## 状态流转

```
idle → preparing → ready → playing ⇄ paused
                     ↓         ↓
                  buffering ←──┘
                     ↓
                  playing → finished
                     ↓
                   failed
```

- **网络模式**：`load()` → `preparing` → `buffering` → `playing`（自动，需先调 `play()`）
- **本地模式**：`load()` → `preparing` → `ready` → `playing`（需手动调 `play()`）
- **缓冲恢复**：`playing` → `buffering`（欠载）→ `playing`（自动恢复）

## 系统要求

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+
- Xcode 15.0+

## 许可证

MIT License
