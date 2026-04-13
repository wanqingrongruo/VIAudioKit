# Changelog

All notable changes to VIAudioKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **解码器映射机制**：在 `VIPlayerConfiguration` 中新增 `decoderMapping` 和 `streamDecoderMapping` 属性，允许为特定文件格式精确指定解码器
  - 支持本地文件解码器映射（`decoderMapping: [String: VIAudioDecoding.Type]`）
  - 支持网络流解码器映射（`streamDecoderMapping: [String: VIStreamDecoding.Type]`）
  - 查找顺序：优先使用映射表，未指定时回退到数组顺序匹配（向后兼容）
  - 性能优化：字典查找 O(1) vs 数组遍历 O(n)

### Changed
- `VIAudioPlayer+Loading.swift` 中的解码器选择逻辑更新为映射优先模式
- README.md 新增"解码器选择机制"章节，详细说明两种使用方式

### Documentation
- 新增 `DECODER_SELECTION_DESIGN.md` - 解码器选择机制设计文档
- 新增 `SPM_FFMPEG_SUPPORT.md` - FFmpeg SPM 支持说明文档
- 更新 `CLAUDE.md` - 添加解码器选择设计模式说明

## [0.1.0] - 2024

### Added
- 初始版本发布
- 跨平台支持（iOS 15+ / macOS 12+）
- 本地和网络音频播放
- 分片下载与 LRU 缓存
- 变速播放（0.5x - 2.0x）
- 多格式支持（MP3, AAC, FLAC, WAV 等）
- FFmpeg 扩展模块（OGG, OPUS, WMA, APE）
- 混音播放功能（VIMixingDecoder）
- 完善的缓冲状态管理
- 自定义日志系统（VILogging 协议）
- CocoaPods 和 Swift Package Manager 支持

[Unreleased]: https://github.com/wanqingrongruo/VIAudioKit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wanqingrongruo/VIAudioKit/releases/tag/v0.1.0
