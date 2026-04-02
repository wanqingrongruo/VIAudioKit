# VIAudioKit

跨平台（iOS / macOS）音频播放框架，基于 `AVAudioEngine` 渲染，支持本地与网络音频、分片下载缓存、自定义解码器、变速播放以及完善的缓冲状态管理。

## 特性

- **多平台**：iOS 15+ / macOS 12+
- **本地 + 网络**：自动识别 `file://` 与 `http(s)://`，无需手动区分
- **多格式支持**：
  - **内置支持**：MP3, AAC, M4A, FLAC, WAV, AIFF, CAF 等（基于 Apple AudioToolbox）
  - **FFmpeg 扩展**：OGG, OPUS, WMA, APE 等复杂格式（通过可选的 `VIAudioFFmpeg` 模块集成 FFmpegKit）
- **分片下载与缓存**：HTTP Range 请求分片下载，LRU 缓存淘汰，支持 seek 时按需下载，同一音频不同 URL 可映射为相同缓存键
- **变速播放**：通过 `AVAudioUnitTimePitch` 实现 0.5x – 2.0x 变速
- **缓冲状态机**：可配置的缓冲阈值（初始起播 / seek 后 / 欠载恢复），自动网络恢复重试
- **完善的日志系统**：提供 `VILogging` 协议，可自由接入你的业务日志组件（如 CocoaLumberjack）
- **双集成方式**：支持 Swift Package Manager 和 CocoaPods

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    VIAudioPlayer                     │
│  (状态机 · 缓冲控制 · 对外 API · Delegate 回调)       │
├───────────────────────┬─────────────────────────────┤
│   本地路径 (Pull)      │     网络流式 (Push)          │
│                       │                             │
│  VILocalFileSource    │  VIPushAudioSource           │
│       ↓               │  (NWPathMonitor · 自动重试)  │
│  VINativeDecoder      │       ↓                     │
│  VIFFmpegDecoder      │  VIStreamDecoder             │
│                       │  VIFFmpegStreamDecoder       │
│       ↓               │       ↓                     │
│  VIAudioBufferQueue   │   VIAudioBufferQueue        │
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
| **VIAudioDownloader** | `Sources/VIAudioDownloader/` | 下载缓存层：分片下载、Range 请求、LRU 缓存、日志系统 `VILogger` |
| **VIAudioFFmpeg** | `Sources/VIAudioFFmpeg/` | *(可选模块)* FFmpeg 扩展解码层，支持 OGG/OPUS/WMA/APE，包含 Push 和 Pull 两种解码器实现 |

## 集成

### CocoaPods

在 Podfile 中可以按需引入模块：

```ruby
# 仅引入核心功能 (AudioToolbox 支持的常规格式)
pod 'VIAudioKit', :path => '../VIAudioKit'

# 如果需要支持 OGG/WMA 等扩展格式，引入 FFmpeg subspec:
pod 'VIAudioKit', :path => '../VIAudioKit', :subspecs => ['Core', 'FFmpeg']
```
*注意：如果引入了 FFmpeg，需要在 Podfile 顶部指定静态链接：`use_frameworks! :linkage => :static`。*

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/example/VIAudioKit.git", from: "0.1.0")
]

// Target 依赖
.target(dependencies: [
    .product(name: "VIAudioPlayer", package: "VIAudioKit"),
    .product(name: "VIAudioFFmpeg", package: "VIAudioKit") // 可选 FFmpeg
])
```

## 快速上手

### 基本播放

```swift
import VIAudioKit  
// 如果集成了 FFmpeg，额外 import:
// import VIAudioFFmpeg

let player = VIAudioPlayer()

// 若需要 OGG/OPUS 等格式支持，注册 FFmpeg 解码器：
player.decoderTypes.append(VIFFmpegDecoder.self)
player.streamDecoderTypes.append(VIFFmpegStreamDecoder.self)

player.delegate = self

// 播放本地文件
player.load(url: Bundle.main.url(forResource: "song", withExtension: "flac")!)
player.play()

// 播放网络音频（缓冲状态会自动通过 Delegate 通知）
player.load(url: URL(string: "https://example.com/song.opus")!)
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
        // 更新播放进度、总时长
    }
    
    func player(_ player: VIAudioPlayer, didUpdateBuffer state: VIBufferState) {
        // 监控底部缓冲队列健康度 (.empty, .buffering(progress:), .sufficient, .full)
    }

    func player(_ player: VIAudioPlayer, didReceiveError error: VIPlayerError) {
        // 处理运行期错误
    }
}
```

### 接入自定义日志组件

你可以通过实现 `VILogging` 协议，将 VIAudioKit 的内部运行日志（含网络异常、解码丢包等）统一转发到你 App 的日志系统中。

```swift
import VIAudioKit

class MyAppLogger: VILogging {
    func log(level: VILogLevel, message: String) {
        switch level {
        case .debug:   MyLogger.debug("AudioKit: \(message)")
        case .info:    MyLogger.info("AudioKit: \(message)")
        case .warning: MyLogger.warn("AudioKit: \(message)")
        case .error:   MyLogger.error("AudioKit: \(message)")
        case .off:     break
        }
    }
}

// 在 App 启动时注入
VILogger.level = .debug // 控制输出级别
VILogger.customLogger = MyAppLogger()
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

// 清空所有缓存
player.removeAllCache()
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

// 去除云存储签名参数以合并相同文件的缓存键（阿里云 OSS / AWS S3 等）
dlConfig.urlCanonicalizer = VIDownloaderConfiguration.stripQueryCanonicalizer

// 自定义播放器起播配置
let config = VIPlayerConfiguration(
    downloaderConfiguration: dlConfig,
    decodeBufferCount: 16,               // 解码缓冲区数量
    framesPerBuffer: 8192,               // 每个缓冲区帧数
    secondsRequiredToStartPlaying: 1.0,  // 初始起播需缓冲的时长
    secondsRequiredAfterSeek: 0.5,       // seek 后需缓冲的时长
    secondsRequiredAfterBufferUnderrun: 3.0  // 发生卡顿恢复时需缓冲的时长
)

let player = VIAudioPlayer(configuration: config)
```

## 扩展解码器协议

如果你需要支持专属的音频格式，可以实现对应的解码协议并插入播放器：

- `VIAudioDecoding`: 用于读取本地完整文件（Pull 模式）。
- `VIStreamDecoding`: 用于解析网络推送的数据流（Push 模式）。

```swift
final class MyOggStreamDecoder: VIStreamDecoding {
    static var supportedExtensions: Set<String> { ["ogg", "opus"] }
    required init() {}
    // 实现 open, feed, seek, flush, close 等方法...
}

// 注册
player.streamDecoderTypes.append(MyOggStreamDecoder.self)
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

- **网络模式**：`load()` → `preparing` → `buffering` → `playing`（支持预触发：`preparing` 或 `buffering` 阶段调用 `play()` 即可在就绪后自动播放）
- **本地模式**：`load()` → `preparing` → `ready` → `playing`（支持预触发：`preparing` 阶段调用 `play()` 即可在就绪后自动播放）
- **缓冲恢复**：`playing` → 遇到网络波动音频耗尽 → `buffering`（欠载）→ 网络恢复满足 `secondsRequiredAfterBufferUnderrun` → 自动回到 `playing`

## 系统要求

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+
- Xcode 15.0+

## 许可证

MIT License
