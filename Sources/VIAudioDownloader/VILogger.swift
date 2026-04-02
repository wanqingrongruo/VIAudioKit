import Foundation
import os

/// Logging levels for VIAudioKit.
public enum VILogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case off = 4

    public static func < (lhs: VILogLevel, rhs: VILogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Configurable logger for VIAudioKit. Uses `os_log` under the hood.
/// Set `VILogger.level` to control verbosity; defaults to `.off` in release builds.
///
/// **Xcode 控制台看不到日志？** `os_log` 的 Debug 级别在系统日志里常被过滤。将 `echoToConsole` 设为 `true`
/// 会同时 `print` 到标准输出，在 Xcode 底部 Run 控制台可直接看到（无需勾选 “Include Debug Messages”）。
public enum VILogger {

    #if DEBUG
    public static var level: VILogLevel = .debug
    #else
    public static var level: VILogLevel = .off
    #endif

    /// 为 `true` 时，在写入 `os_log` 的同时 `print` 一行，便于在 Xcode Run 控制台调试。
    /// Release 默认 `false`；调试网络解码时可在 App 启动时设为 `true` 并配合 `level = .debug`。
    #if DEBUG
    public static var echoToConsole: Bool = true
    #else
    public static var echoToConsole: Bool = false
    #endif

    private static let subsystem = "com.viaudiokit"
    private static let osLog = OSLog(subsystem: subsystem, category: "VIAudioKit")

    private static func emitConsoleIfNeeded(_ text: String) {
        if echoToConsole {
            print(text)
        }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard level <= .debug else { return }
        let text = message()
        emitConsoleIfNeeded(text)
        os_log(.debug, log: osLog, "%{public}s", text)
    }

    public static func info(_ message: @autoclosure () -> String) {
        guard level <= .info else { return }
        let text = message()
        emitConsoleIfNeeded(text)
        os_log(.info, log: osLog, "%{public}s", text)
    }

    public static func warning(_ message: @autoclosure () -> String) {
        guard level <= .warning else { return }
        let text = message()
        emitConsoleIfNeeded(text)
        os_log(.default, log: osLog, "⚠️ %{public}s", text)
    }

    public static func error(_ message: @autoclosure () -> String) {
        guard level <= .error else { return }
        let text = message()
        emitConsoleIfNeeded(text)
        os_log(.error, log: osLog, "%{public}s", text)
    }
}
