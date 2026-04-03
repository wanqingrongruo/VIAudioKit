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
pod 'VIAudioKit'
```

如果你希望支持 OGG, OPUS, WMA 等扩展格式，可以通过直接引入 Github 仓库地址的方式拉取完整的 FFmpeg 扩展模块：

```ruby
# 通过直连 Github 仓库的方式，拉取完整的带有 FFmpeg 子模块的版本
pod 'VIAudioKit', :git => 'https://github.com/wanqingrongruo/VIAudioKit.git', :tag => '0.1.0', :subspecs => ['Core', 'FFmpeg']

# 必须在宿主 App 的 Podfile 中补充 FFmpegKit 的源地址重定向（详见下方注意2）
pod 'ffmpeg-kit-ios-full', :podspec => 'https://raw.githubusercontent.com/luthviar/ffmpeg-kit-ios-full/main/ffmpeg-kit-ios-full.podspec'

# 或者，如果宿主 App 已经 手动导入 了 FFmpegKit 的 Framework/XCFramework 库
# 使用免依赖的 FFmpeg-Manual subspec，避免重复链接导致的 Duplicate Symbols 报错
pod 'VIAudioKit', :git => 'https://github.com/wanqingrongruo/VIAudioKit.git', :tag => '0.1.0', :subspecs => ['Core', 'FFmpeg-Manual']
```
*注意：*
1. *如果引入了包含 FFmpeg 的模块，需要在 Podfile 顶部指定静态链接：`use_frameworks! :linkage => :static`。*
2. *因为官方 `ffmpeg-kit` 的 CocoaPods 默认源存在下载链接失效（404）的问题，且 Podspec 规范不允许库作者在发布到官方 Trunk 的 `.podspec` 中包含会引发 404 的外部依赖，因此官方中央仓库的 `VIAudioKit` 默认只包含 `Core` 模块。如果需要 `FFmpeg` 支持，请务必使用如上 `:git` 的方式直接从 Github 获取。同时，**必须在宿主 App 的 Podfile 中显式指定**修复过的 `ffmpeg-kit-ios-full` podspec 地址。如果不加这行重定向，`pod install` 将因为找不到依赖而报错。*
3. **针对手动导入 FFmpegKit 的场景**：
   如果你选择了 `FFmpeg-Manual`，CocoaPods 将不会帮你下载和链接 FFmpeg。你必须确保：
   - 宿主工程内已经正确链接了相关的 `ffmpegkit.xcframework` 库文件。
   - 由于 CocoaPods 编译 `VIAudioKit/FFmpeg-Manual` 源码时需要能够找到 FFmpeg 的 C 头文件（如 `<libavformat/avformat.h>`），你需要保证在宿主工程的 `Header Search Paths` 或者配置给 CocoaPods 的 `USER_HEADER_SEARCH_PATHS` 中，包含了该 Framework 的 Headers 路径，使得子模块内的桥接代码能够正常解析。

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

### 播放控制与混音播放

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

// 【混音播放 (Audio Mixing)】
// VIAudioKit 原生提供了 `VIMixingDecoder`，支持将多个本地音频无缝混合为单一流式轨道播放。
// 你只需要将包含多个本地音频绝对路径的数组序列化为 JSON，并保存为扩展名 `.vimix` 的文件：
let url1 = Bundle.main.url(forResource: "vocal", withExtension: "mp3")!
let url2 = Bundle.main.url(forResource: "beat", withExtension: "m4a")!

let mixFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("track.vimix")
let jsonList = [url1.absoluteString, url2.absoluteString]
let jsonData = try! JSONSerialization.data(withJSONObject: jsonList, options: [])
try! jsonData.write(to: mixFileURL)

// 像播放普通音频一样加载该 `.vimix` 文件即可！
// 底层使用 Accelerate 框架实现高性能流式混音，且同样支持变速（rate）与 Seek：
player.load(url: mixFileURL)
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


## 发布指令
```
# 1. 备份完整的 podspec
cp VIAudioKit.podspec /tmp/VIAudioKit.podspec.bak
# 2. 临时剔除 FFmpeg 子模块配置，避免被官方服务器拦截 404
sed -i '' '/s.subspec .FFmpeg. do/,/^  end/d' VIAudioKit.podspec
sed -i '' '/s.subspec .FFmpeg-Manual. do/,/^  end/d' VIAudioKit.podspec
# 3. 执行发布（只发布 Core 模块，加上忽略警告参数）
pod trunk push VIAudioKit.podspec --allow-warnings
# 4. 看到 🎉 Congrats 后，恢复完整的 podspec
mv /tmp/VIAudioKit.podspec.bak VIAudioKit.podspec
```
