import Foundation

/// The "Send crash reports" setting. Default on (opt-out).
public enum CrashReportingPreference {
    public static let key = "crashReportingEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
