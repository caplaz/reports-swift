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
}
