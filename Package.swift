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
