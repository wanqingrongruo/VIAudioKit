// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VIAudioKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "VIAudioPlayer", targets: ["VIAudioPlayer"]),
        .library(name: "VIAudioDownloader", targets: ["VIAudioDownloader"]),
        .library(name: "VIAudioDecoder", targets: ["VIAudioDecoder"]),
        .library(name: "VIAudioFFmpeg", targets: ["VIAudioFFmpeg"]),
    ],
    dependencies: [
        // FFmpeg 支持仅在 CocoaPods 下可用
        // 经过测试，现有的 SPM FFmpeg 包都无法提供可用的 Swift 模块
    ],
    targets: [
        .target(
            name: "VIAudioDownloader",
            path: "Sources/VIAudioDownloader"
        ),
        .target(
            name: "VIAudioDecoder",
            dependencies: ["VIAudioDownloader"],
            path: "Sources/VIAudioDecoder"
        ),
        .target(
            name: "VIAudioPlayer",
            dependencies: ["VIAudioDownloader", "VIAudioDecoder"],
            path: "Sources/VIAudioPlayer"
        ),
        .target(
            name: "VIAudioFFmpeg",
            dependencies: [
                "VIAudioDecoder"
            ],
            path: "Sources/VIAudioFFmpeg",
            exclude: ["include"]
        ),
        .testTarget(
            name: "VIAudioDownloaderTests",
            dependencies: ["VIAudioDownloader"],
            path: "Tests/VIAudioDownloaderTests"
        ),
        .testTarget(
            name: "VIAudioPlayerTests",
            dependencies: ["VIAudioPlayer"],
            path: "Tests/VIAudioPlayerTests"
        ),
    ]
)
