# SPM FFmpeg 支持说明

## 当前状态

VIAudioKit 完全支持 Swift Package Manager (SPM)，但 **FFmpeg 扩展功能仅在 CocoaPods 环境下可用**。

## 功能对比

### ✅ SPM 完全支持（核心功能）

- **VIAudioPlayer** - 完整的音频播放器
- **VIAudioDownloader** - 分块下载和 LRU 缓存
- **VIAudioDecoder** - 原生解码器
- **支持的格式**：MP3, AAC, WAV, FLAC, M4A, ALAC 等所有系统原生支持的格式

### ⚠️ CocoaPods 独占（FFmpeg 扩展）

- **VIAudioFFmpeg** - FFmpeg 解码器
- **额外支持的格式**：OGG, Opus, WMA, APE, WavPack

## 为什么 SPM 不支持 FFmpeg？

### 技术原因

经过详细调查和测试，发现所有现有的 FFmpeg SPM 包都存在以下问题：

#### 1. **yangliu-1995/ffmpeg-kit-spm**
- ❌ Binary XCFrameworks 缺少 Swift 模块定义
- ❌ 没有 `module.modulemap` 文件
- ❌ Swift 编译器无法识别这些 frameworks
- ✅ 仅适用于 Objective-C 项目

#### 2. **kewlbear/FFmpeg-iOS**
- ❌ 主要用于 FFmpeg 命令行工具封装
- ❌ 不暴露 FFmpeg C API 给 Swift
- ❌ 设计目标是提供 `ffmpeg` 命令，不是库

#### 3. **kingslay/FFmpegKit**
- ⏸️ 依赖解析问题，未能成功测试

### 根本问题

1. **FFmpeg 是纯 C 库**
   - 需要正确的 modulemap 才能被 Swift 导入
   - Binary XCFrameworks 通常缺少 Swift 模块定义

2. **SPM 的限制**
   - 对 C 库的支持不如 CocoaPods 灵活
   - 无法像 CocoaPods 那样通过 `pod_target_xcconfig` 自定义搜索路径
   - Binary targets 的模块暴露机制不完善

3. **CocoaPods 为什么可以？**
   - 使用 `ffmpeg-kit-ios-full` 包
   - 提供完整的头文件结构
   - 支持自定义 modulemap 配置
   - 可以通过 `pod_target_xcconfig` 设置搜索路径

## 使用建议

### 如果只需要常见格式（推荐）

使用 **SPM**，系统原生支持已足够：

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/wanqingrongruo/VIAudioKit.git", from: "0.1.0")
]
```

**支持的格式**：
- MP3, AAC, M4A (最常用)
- WAV, AIFF (无损)
- FLAC, ALAC (无损压缩)
- 覆盖 95%+ 的使用场景

### 如果需要 OGG/Opus/WMA 等格式

使用 **CocoaPods**：

```ruby
# Podfile
pod 'VIAudioKit/FFmpeg'
```

**额外支持的格式**：
- OGG, Opus (开源音频格式)
- WMA (Windows Media Audio)
- APE (Monkey's Audio)
- WavPack

## 测试过的替代方案

| 包名 | 测试结果 | 问题 |
|------|---------|------|
| yangliu-1995/ffmpeg-kit-spm | ❌ 失败 | 无 Swift 模块定义 |
| kewlbear/FFmpeg-iOS | ❌ 不适用 | 仅提供命令行工具 |
| kingslay/FFmpegKit | ⏸️ 未完成 | 依赖解析问题 |

## 未来可能的解决方案

1. **等待 ffmpeg-kit-spm 更新** - 添加 Swift 模块支持
2. **创建自定义 FFmpeg XCFramework** - 包含正确的模块定义
3. **使用其他 FFmpeg SPM 包** - 持续关注社区新方案
4. **贡献到现有包** - 帮助改进 ffmpeg-kit-spm

## 相关资源

- [ffmpeg-kit-spm 仓库](https://github.com/yangliu-1995/ffmpeg-kit-spm)
- [ffmpeg-kit-ios-full (CocoaPods)](https://github.com/arthenica/ffmpeg-kit)
- [kewlbear/FFmpeg-iOS](https://github.com/kewlbear/FFmpeg-iOS)
- [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit)
- [Swift Package Manager 文档](https://swift.org/package-manager/)

---

**结论**：当前最实用的方案是根据需求选择 SPM（常见格式）或 CocoaPods（扩展格式）。这不是 VIAudioKit 的限制，而是整个 Swift 生态系统中 FFmpeg 集成的普遍挑战。
