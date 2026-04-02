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
public enum VILogger {

    #if DEBUG
    public static var level: VILogLevel = .debug
    #else
    public static var level: VILogLevel = .off
    #endif

    private static let subsystem = "com.viaudiokit"
    private static let osLog = OSLog(subsystem: subsystem, category: "VIAudioKit")

    public static func debug(_ message: @autoclosure () -> String) {
        guard level <= .debug else { return }
        os_log(.debug, log: osLog, "%{public}s", message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        guard level <= .info else { return }
        os_log(.info, log: osLog, "%{public}s", message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        guard level <= .warning else { return }
        os_log(.default, log: osLog, "⚠️ %{public}s", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        guard level <= .error else { return }
        os_log(.error, log: osLog, "%{public}s", message())
    }
}
