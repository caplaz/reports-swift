import Foundation

/// The "Send crash reports" and "Share detailed diagnostics" settings.
public enum CrashReportingPreference {
    /// "Send crash reports". Default on (opt-out).
    public static let key = "crashReportingEnabled"
    /// "Share detailed diagnostics". Default off (opt-in). Read when the SDK starts; the
    /// diagnostic profile needs this **and** `key` on.
    public static let detailedDiagnosticsKey = "crashReportingDetailedDiagnostics"
    /// The profile the SDK last started with (`PrivacyProfile.rawValue`).
    static let lastProfileKey = "crashReportingLastProfile"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    public static func isDetailedDiagnosticsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: detailedDiagnosticsKey) as? Bool ?? false
    }

    public static func setDetailedDiagnostics(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: detailedDiagnosticsKey)
    }

    static func lastProfile(in defaults: UserDefaults) -> CrashReporting.PrivacyProfile {
        defaults.string(forKey: lastProfileKey).flatMap(CrashReporting.PrivacyProfile.init(rawValue:)) ?? .strict
    }

    static func setLastProfile(_ profile: CrashReporting.PrivacyProfile, in defaults: UserDefaults) {
        defaults.set(profile.rawValue, forKey: lastProfileKey)
    }

    /// A whole-cache purge was requested (reporting off at launch, or a diagnostic → strict
    /// downgrade) and has not completed yet. Set before deleting, cleared only after the
    /// deletion succeeded, so a failed or interrupted purge is finished by the next SDK start.
    static let pendingPurgeKey = "crashReportingPendingPurge"

    static func hasPendingPurge(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pendingPurgeKey)
    }

    static func setPendingPurge(_ pending: Bool, in defaults: UserDefaults) {
        if pending { defaults.set(true, forKey: pendingPurgeKey) } else { defaults.removeObject(forKey: pendingPurgeKey) }
    }

    /// Metric envelopes recorded before an opt-out may still be on disk (metrics spec §4.2).
    /// Set at every opt-out before deleting; cleared only by the next SDK start's sweep or a
    /// whole-cache purge: an envelope can be written after the in-process sweeps.
    static let pendingMetricSweepKey = "crashReportingPendingMetricSweep"

    static func hasPendingMetricSweep(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pendingMetricSweepKey)
    }

    static func setPendingMetricSweep(_ pending: Bool, in defaults: UserDefaults) {
        if pending { defaults.set(true, forKey: pendingMetricSweepKey) } else { defaults.removeObject(forKey: pendingMetricSweepKey) }
    }
}
