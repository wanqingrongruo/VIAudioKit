# VIAudioKit

## Project Overview

VIAudioKit 是一个跨平台 (iOS 15+ / macOS 12+) 音频播放框架，支持本地文件和网络流媒体播放。使用 Swift 5.9+ 开发，通过 SPM 和 CocoaPods 分发。

## Architecture

项目采用四模块分层架构：

| 模块 | 职责 |
|------|------|
| **VIAudioPlayer** | 播放器状态机、AVAudioEngine 渲染、缓冲队列调度 |
| **VIAudioDecoder** | 解码协议与实现 (Pull/Push 双模式) |
| **VIAudioDownloader** | HTTP Range 分块下载、LRU 缓存管理 |
| **VIAudioFFmpeg** | 可选 FFmpeg 编解码扩展 (OGG/OPUS/WMA/APE) |

依赖方向：Player → Decoder → Downloader；FFmpeg → Decoder (可选)

### Key Design Patterns

- **Protocol-driven**: `VIAudioDecoding` (pull)、`VIStreamDecoding` (push)、`VIAudioSource`、`VILogging` 等协议驱动扩展
- **Dual-path decoding**: 本地文件走 Pull 模式 (ExtAudioFile)，网络流走 Push 模式 (AudioFileStream + AudioConverter)
- **Configuration objects**: 使用不可变 struct 配置 (`VIPlayerConfiguration`, `VIDownloaderConfiguration`)
- **Decoder selection**: 支持两种解码器选择方式
  - 数组顺序匹配：通过 `decoderTypes`/`streamDecoderTypes` 数组按顺序查找
  - 精确映射（推荐）：通过 `decoderMapping`/`streamDecoderMapping` 字典为特定格式指定解码器
- **Delegate pattern**: `VIAudioPlayerDelegate` 回调状态/进度/错误

### Concurrency

- `os_unfair_lock`: 音频渲染线程等热路径
- `NSLock`: 较长临界区
- 主线程 dispatch UI 回调
- 专用 decode 线程处理解码

## Naming Conventions

- 所有公开类型使用 `VI` 前缀
- 类: `VIAudioPlayer`, `VINativeDecoder`, `VIChunkedDownloader`
- 协议: `VIAudioDecoding`, `VIStreamDecoding`, `VILogging`
- 枚举: `VIPlayerState`, `VIBufferState`, `VIDecoderError`
- 配置: `VIPlayerConfiguration`, `VIDownloaderConfiguration`

## Build & Run

```bash
# SPM build
swift build

# Run tests
swift test

# Example app (CocoaPods)
cd Example && pod install && open VIAudioKitDemo.xcworkspace
```

## Dependencies

- **ffmpeg-kit-spm** (v6.0.0): 可选，用于扩展格式支持
- 系统框架: AVFoundation, AudioToolbox, Foundation, Network, CryptoKit

## Testing

使用 XCTest 框架，测试位于 `Tests/` 目录：
- `VIAudioDownloaderTests/`: 缓存、Range 解析、配置
- `VIAudioPlayerTests/`: 缓冲队列行为

## Code Guidelines

- 新增代码遵循现有的 VI 前缀命名规范
- 协议优先设计，新功能优先考虑协议扩展
- 线程安全：音频渲染热路径用 `os_unfair_lock`，其他用 `NSLock`
- 公开 API 提供中英文注释
- 保持模块边界清晰，避免跨模块循环依赖
- **每次修改代码后，检查变更是否影响 README.md 中的内容（如 API 示例、功能列表、架构说明、集成指南等），如需要则同步更新 README.md**
