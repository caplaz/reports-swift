import Foundation
import Sentry

extension CrashReporting {
    /// Severity of a structured log. Only failure levels exist, to keep volume low.
    public enum LogLevel: Sendable {
        case warning, error

        var sentryLevel: SentryLog.Level {
            switch self {
            case .warning: .warn
            case .error: .error
            }
        }
    }

    /// Sends a structured log whose body is `message`. The message is a compile-time constant:
    /// never user data. Attributes are `report.op` plus the SDK's non-identifying release,
    /// environment, SDK, OS and device-model attributes.
    ///
    /// A no-op before `start`, while reporting is off, when the SDK isn't running, or when
    /// `configuration.logsEnabled` is false. Identical logs (same level, operation and body) are
    /// sent at most once per minute per process.
    public static func log(_ level: LogLevel, _ message: StaticString, operation: Operation) {
        guard canLog() != nil else { return }
        emit(makeLog(level, message: message, operation: operation), level: level, operation: operation)
    }

    /// Sends a structured log whose body is `"<operation> <describeError(error)>"` — never the
    /// error value, its description or `userInfo`. Attributes are `report.op`, `report.error`
    /// (= `describeError(error)`) plus the SDK's non-identifying attributes.
    ///
    /// Same no-op and throttling rules as `log(_:_:operation:)` with a message.
    public static func log(_ level: LogLevel, _ error: any Error, operation: Operation) {
        guard let configuration = canLog() else { return }
        emit(makeLog(level, error: error, operation: operation, describe: configuration.describeError),
             level: level, operation: operation)
    }

    static func makeLog(_ level: LogLevel, message: StaticString, operation: Operation) -> ExpectedLog {
        ExpectedLog(
            level: level.sentryLevel,
            body: message.description,
            attributes: [
                CrashReportSanitizer.logOperationKey: operation.rawValue,
                CrashReportSanitizer.logSourceKey: CrashReportSanitizer.logSource
            ])
    }

    static func makeLog(
        _ level: LogLevel, error: any Error, operation: Operation, describe: (any Error) -> String
    ) -> ExpectedLog {
        let description = describe(error)
        return ExpectedLog(
            level: level.sentryLevel,
            body: "\(operation.rawValue) \(description)",
            attributes: [
                CrashReportSanitizer.logOperationKey: operation.rawValue,
                CrashReportSanitizer.logErrorKey: description,
                CrashReportSanitizer.logSourceKey: CrashReportSanitizer.logSource
            ])
    }

    private static func emit(_ log: ExpectedLog, level: LogLevel, operation: Operation) {
        guard logThrottle.admit(LogThrottle.Key(level: level, operation: operation, body: log.body)) else { return }
        let attributes: [String: Any] = log.attributes
        // sentry-cocoa runs `beforeSendLog` synchronously on this thread (see
        // docs/specs/2026-10-13-logs-design.md), where the sanitizer matches it against the
        // pending log. The `String` overloads add no message template/parameter attributes.
        PendingLog.with(log) {
            switch level {
            case .warning: SentrySDK.logger.warn(log.body, attributes: attributes)
            case .error: SentrySDK.logger.error(log.body, attributes: attributes)
            }
        }
    }
}

/// The log `CrashReporting.log` is emitting: the only shape `beforeSendLog` lets through.
struct ExpectedLog: Equatable {
    let level: SentryLog.Level
    let body: String
    /// ReportsKit's own `report.*` attributes.
    let attributes: [String: String]
}

/// Thread-local slot holding the log being emitted on the current thread, so `beforeSendLog`
/// can tell ReportsKit's logs from any other `SentryLog` (direct `SentrySDK.logger` calls,
/// integrations, forged markers).
enum PendingLog {
    private final class Box {
        let log: ExpectedLog
        init(_ log: ExpectedLog) { self.log = log }
    }

    private static let key = "io.caplaz.ReportsKit.pendingLog"

    static var current: ExpectedLog? {
        (Thread.current.threadDictionary[key] as? Box)?.log
    }

    static func with<T>(_ log: ExpectedLog, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = Box(log)
        defer { dictionary[key] = previous }
        return try body()
    }
}
