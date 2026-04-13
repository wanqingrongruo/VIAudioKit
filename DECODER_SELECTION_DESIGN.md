# 解码器选择机制设计

## 当前问题

当前设计使用顺序匹配：
```swift
// 当前实现
guard let decoderType = self.decoderTypes.first(where: {
    $0.supportedExtensions.contains(ext)
}) else {
    throw VIPlayerError.decoderCreationFailed(...)
}
```

**问题**：
1. 无法指定特定格式使用特定解码器
2. 如果多个解码器支持同一格式，只能用第一个
3. 缺乏灵活性

## 设计方案

### 方案 1：解码器优先级映射（推荐）

在 `VIPlayerConfiguration` 中添加解码器映射：

```swift
public struct VIPlayerConfiguration {
    // ... 现有配置 ...
    
    /// 为特定文件扩展名指定解码器类型
    /// 如果未指定，则使用 decoderTypes 数组顺序匹配
    public var decoderMapping: [String: VIAudioDecoding.Type] = [:]
    
    /// 为特定文件扩展名指定流解码器类型
    public var streamDecoderMapping: [String: VIStreamDecoding.Type] = [:]
}
```

**使用示例**：
```swift
var config = VIPlayerConfiguration()

// 指定 OGG 格式使用 FFmpeg 解码器
config.decoderMapping["ogg"] = VIFFmpegDecoder.self

// 指定 MP3 使用原生解码器（即使 FFmpeg 也支持）
config.decoderMapping["mp3"] = VINativeDecoder.self

// 流解码器同理
config.streamDecoderMapping["opus"] = VIFFmpegStreamDecoder.self

let player = VIAudioPlayer(configuration: config)
```

**实现**：
```swift
// 在 VIAudioPlayer+Loading.swift 中修改
func loadLocalFile(url: URL, extensionHint: String?, thisLoad: Int, fallbackURL: URL? = nil) {
    // ...
    
    let ext = (extensionHint?.isEmpty == false) ? extensionHint! : source.fileExtension
    
    // 1. 先查找映射
    let decoderType: VIAudioDecoding.Type
    if let mappedType = configuration.decoderMapping[ext] {
        decoderType = mappedType
    } else {
        // 2. 回退到顺序匹配
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
    // ...
}
```

**优点**：
- ✅ 向后兼容（不指定映射时使用原有逻辑）
- ✅ 灵活性高
- ✅ 配置清晰
- ✅ 性能好（直接查找，无需遍历）

---

### 方案 2：解码器优先级系统

为解码器添加优先级：

```swift
public protocol VIAudioDecoding: AnyObject {
    static var supportedExtensions: Set<String> { get }
    
    /// 解码器优先级，数值越大优先级越高
    /// 默认为 0，系统原生解码器通常为 100
    static var priority: Int { get }
    
    // ... 其他方法 ...
}

extension VIAudioDecoding {
    static var priority: Int { 0 }
}
```

**使用示例**：
```swift
// 原生解码器高优先级
extension VINativeDecoder {
    static var priority: Int { 100 }
}

// FFmpeg 解码器低优先级（作为备选）
extension VIFFmpegDecoder {
    static var priority: Int { 50 }
}

// 自动按优先级排序
player.decoderTypes.sort { $0.priority > $1.priority }
```

**优点**：
- ✅ 自动排序
- ✅ 扩展性好
- ❌ 需要修改协议（可能破坏兼容性）
- ❌ 不够灵活（无法针对特定格式）

---

### 方案 3：解码器工厂模式

创建解码器工厂：

```swift
public protocol VIDecoderFactory {
    func decoder(for extension: String, source: VIAudioSource) throws -> VIAudioDecoding?
}

public class VIDefaultDecoderFactory: VIDecoderFactory {
    var decoderTypes: [VIAudioDecoding.Type]
    var mapping: [String: VIAudioDecoding.Type]
    
    public func decoder(for extension: String, source: VIAudioSource) throws -> VIAudioDecoding? {
        // 先查映射，再顺序匹配
        if let type = mapping[extension] {
            return try type.init(source: source)
        }
        
        guard let type = decoderTypes.first(where: {
            $0.supportedExtensions.contains(extension)
        }) else {
            return nil
        }
        
        return try type.init(source: source)
    }
}

// 在 VIPlayerConfiguration 中
public var decoderFactory: VIDecoderFactory = VIDefaultDecoderFactory()
```

**优点**：
- ✅ 最灵活（可以完全自定义逻辑）
- ✅ 可扩展性强
- ❌ 复杂度高
- ❌ 对简单场景过度设计

---

## 推荐实现：方案 1（解码器映射）

### 完整实现代码

#### 1. 更新 VIPlayerConfiguration

```swift
// Sources/VIAudioPlayer/VIPlayerConfiguration.swift

public struct VIPlayerConfiguration {
    // ... 现有配置 ...
    
    /// 为特定文件扩展名指定 Pull 模式解码器
    /// 
    /// 使用场景：
    /// - 多个解码器支持同一格式时，指定优先使用哪个
    /// - 强制某些格式使用特定解码器
    /// 
    /// 示例：
    /// ```swift
    /// config.decoderMapping["ogg"] = VIFFmpegDecoder.self
    /// config.decoderMapping["mp3"] = VINativeDecoder.self
    /// ```
    public var decoderMapping: [String: VIAudioDecoding.Type] = [:]
    
    /// 为特定文件扩展名指定 Push 模式解码器（网络流）
    public var streamDecoderMapping: [String: VIStreamDecoding.Type] = [:]
    
    public init() {
        // ... 现有初始化 ...
    }
}
```

#### 2. 更新 VIAudioPlayer+Loading.swift

```swift
// 在 loadLocalFile 方法中
func loadLocalFile(url: URL, extensionHint: String?, thisLoad: Int, fallbackURL: URL? = nil) {
    decodeQueue.async { [weak self] in
        guard let self else { return }
        
        // ... 现有代码 ...
        
        do {
            let source = try VILocalFileSource(fileURL: url, extensionOverride: extensionHint)
            self.source = source
            
            let ext = (extensionHint?.isEmpty == false) ? extensionHint! : source.fileExtension
            VILogger.debug("[VIAudioPlayer] load: ext=\(ext) size=\(source.contentLength ?? -1)")
            
            // 🆕 优先查找映射
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
            // ... 其余代码保持不变 ...
        } catch {
            // ... 错误处理 ...
        }
    }
}

// 在 loadNetworkFile 方法中
func loadNetworkFile(url: URL, thisLoad: Int) {
    let ext = url.pathExtension.lowercased()
    self.networkFileExt = ext
    
    let ps = VIPushAudioSource(...)
    
    // 🆕 优先查找映射
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
    // ... 其余代码保持不变 ...
}
```

### 使用示例

#### 基础使用（向后兼容）

```swift
// 不指定映射，使用默认顺序匹配
let player = VIAudioPlayer()
player.load(url: URL(string: "https://example.com/audio.mp3")!)
```

#### 指定解码器

```swift
var config = VIPlayerConfiguration()

// 场景 1：强制 OGG 使用 FFmpeg（即使有其他解码器）
config.decoderMapping["ogg"] = VIFFmpegDecoder.self
config.streamDecoderMapping["ogg"] = VIFFmpegStreamDecoder.self

// 场景 2：MP3 优先使用原生解码器（性能更好）
config.decoderMapping["mp3"] = VINativeDecoder.self

// 场景 3：自定义解码器
config.decoderMapping["custom"] = MyCustomDecoder.self

let player = VIAudioPlayer(configuration: config)
```

#### 动态切换

```swift
// 运行时修改映射（需要重新加载）
player.configuration.decoderMapping["flac"] = VINativeDecoder.self
player.load(url: flacURL)
```

### 优势

1. **向后兼容**：不影响现有代码
2. **灵活性高**：可以精确控制每种格式的解码器
3. **性能好**：字典查找 O(1)
4. **易于理解**：配置清晰直观
5. **可测试**：容易编写单元测试

### 测试用例

```swift
func testDecoderMapping() {
    var config = VIPlayerConfiguration()
    config.decoderMapping["mp3"] = VINativeDecoder.self
    
    let player = VIAudioPlayer(configuration: config)
    player.load(url: mp3URL)
    
    // 验证使用了正确的解码器
    XCTAssertTrue(player.decoder is VINativeDecoder)
}

func testFallbackToDefaultMatching() {
    let config = VIPlayerConfiguration()
    // 不指定映射
    
    let player = VIAudioPlayer(configuration: config)
    player.load(url: mp3URL)
    
    // 应该使用 decoderTypes 数组中第一个支持的
    XCTAssertNotNil(player.decoder)
}
```

## 总结

**推荐使用方案 1（解码器映射）**，因为它：
- 简单直接
- 向后兼容
- 满足所有需求
- 易于维护

需要我实现这个方案吗？
