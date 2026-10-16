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
}
