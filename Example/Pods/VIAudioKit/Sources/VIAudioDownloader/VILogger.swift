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

/// A protocol that allows you to provide a custom logging implementation for VIAudioKit.
public protocol VILogging: Sendable {
    func log(level: VILogLevel, message: String)
}

/// The default logger implementation using `os_log` and optional console printing.
/// Provided if you want to reuse the default logging logic in your custom implementations.
public struct VIDefaultLogger: VILogging {
    public var echoToConsole: Bool
    private let osLog: OSLog

    public init(subsystem: String = "com.viaudiokit", category: String = "VIAudioKit", echoToConsole: Bool = false) {
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.echoToConsole = echoToConsole
    }

    public func log(level: VILogLevel, message: String) {
        if echoToConsole {
            print(message)
        }
        switch level {
        case .debug:
            os_log(.debug, log: osLog, "%{public}s", message)
        case .info:
            os_log(.info, log: osLog, "%{public}s", message)
        case .warning:
            os_log(.default, log: osLog, "⚠️ %{public}s", message)
        case .error:
            os_log(.error, log: osLog, "%{public}s", message)
        case .off:
            break
        }
    }
}

/// Configurable logger for VIAudioKit. Uses `os_log` under the hood by default,
/// but allows injecting a custom `VILogging` implementation.
///
/// **Xcode 控制台看不到日志？** `os_log` 的 Debug 级别在系统日志里常被过滤。将 `echoToConsole` 设为 `true`
/// 会同时 `print` 到标准输出，在 Xcode 底部 Run 控制台可直接看到（无需勾选 “Include Debug Messages”）。
public enum VILogger {

    #if DEBUG
    public static var level: VILogLevel = .debug
    #else
    public static var level: VILogLevel = .off
    #endif

    /// Provide a custom logger here to redirect all VIAudioKit logs.
    /// If `nil`, the default internal logging logic is used.
    public static var customLogger: VILogging?

    /// 为 `true` 时，在写入 `os_log` 的同时 `print` 一行，便于在 Xcode Run 控制台调试。
    /// Release 默认 `false`；调试网络解码时可在 App 启动时设为 `true` 并配合 `level = .debug`。
    #if DEBUG
    public static var echoToConsole: Bool = true
    #else
    public static var echoToConsole: Bool = false
    #endif

    private static let osLog = OSLog(subsystem: "com.viaudiokit", category: "VIAudioKit")

    private static func emitLog(level: VILogLevel, message: String) {
        if let custom = customLogger {
            custom.log(level: level, message: message)
        } else {
            if echoToConsole {
                print(message)
            }
            switch level {
            case .debug:
                os_log(.debug, log: osLog, "%{public}s", message)
            case .info:
                os_log(.info, log: osLog, "%{public}s", message)
            case .warning:
                os_log(.default, log: osLog, "⚠️ %{public}s", message)
            case .error:
                os_log(.error, log: osLog, "%{public}s", message)
            case .off:
                break
            }
        }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard level <= .debug else { return }
        emitLog(level: .debug, message: message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        guard level <= .info else { return }
        emitLog(level: .info, message: message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        guard level <= .warning else { return }
        emitLog(level: .warning, message: message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        guard level <= .error else { return }
        emitLog(level: .error, message: message())
    }
}
