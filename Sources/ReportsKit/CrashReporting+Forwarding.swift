import Foundation
import Sentry

extension CrashReporting {
    /// Severity of a forwarded app log line (`forwardLog`).
    public enum ForwardedLogLevel: Sendable {
        case info, warning, error, fatal

        var sentryLevel: SentryLog.Level {
            switch self {
            case .info: .info
            case .warning: .warn
            case .error: .error
            case .fatal: .fatal
            }
        }
    }

    /// Forwarded logs are emitted here, off the caller's thread (spec §6.2).
    static let forwardQueue = DispatchQueue(label: "io.caplaz.ReportsKit.forwardLog", qos: .utility)

    /// Forwards one line of the app's own log to Sentry Logs — only while `activeProfile` is
    /// `.diagnostic`; a no-op in strict, once "Share detailed diagnostics" is turned off in
    /// this process, before `start`, while reporting is off, when the SDK isn't running or
    /// with `logsEnabled == false`. The body is `message` (truncated to 4,096 characters);
    /// attributes are `report.source = "app-log"`, `report.category = category`,
    /// `report.dropped` when earlier lines were dropped, the installation `user.id` and the
    /// SDK's non-identifying attributes. Budget: an identical line at most once per 10 s, 120
    /// lines per minute, 5,000 per process. Safe to call from any thread; cheap on the caller.
    public static func forwardLog(_ level: ForwardedLogLevel, category: String, message: String) {
        guard activeProfile == .diagnostic, canLog() != nil else { return }
        let body = ForwardBudget.truncated(message)
        guard let dropped = forwardBudget.admit(ForwardBudget.Key(level: level, category: category, body: body))
        else { return }
        let log = makeForwardedLog(level, category: category, body: body, droppedBefore: dropped, timestamp: Date())
        forwardQueue.async { emitForwarded(log, level: level) }
    }

    static func makeForwardedLog(
        _ level: ForwardedLogLevel, category: String, body: String, droppedBefore: Int, timestamp: Date
    ) -> ExpectedLog {
        var attributes = [
            CrashReportSanitizer.logSourceKey: CrashReportSanitizer.forwardedLogSource,
            CrashReportSanitizer.logCategoryKey: category
        ]
        if droppedBefore > 0 { attributes[CrashReportSanitizer.logDroppedKey] = String(droppedBefore) }
        return ExpectedLog(level: level.sentryLevel, body: body, attributes: attributes, timestamp: timestamp)
    }

    private static func emitForwarded(_ log: ExpectedLog, level: ForwardedLogLevel) {
        // Consent or detailed diagnostics may have been turned off since admission.
        guard ConsentGate.shared.isEnabled, activeProfile == .diagnostic else { return }
        let attributes: [String: Any] = log.attributes
        // beforeSendLog runs synchronously on this thread and matches the pending log.
        PendingLog.with(log) {
            switch level {
            case .info: SentrySDK.logger.info(log.body, attributes: attributes)
            case .warning: SentrySDK.logger.warn(log.body, attributes: attributes)
            case .error: SentrySDK.logger.error(log.body, attributes: attributes)
            case .fatal: SentrySDK.logger.fatal(log.body, attributes: attributes)
            }
        }
    }
}
