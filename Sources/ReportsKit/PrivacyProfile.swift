import Foundation

extension CrashReporting {
    /// What a running SDK may send. Chosen once per SDK start from the user's stored settings
    /// (sentry-cocoa reads its options only at `start`); see `activeProfile`.
    public enum PrivacyProfile: String, Sendable, CaseIterable {
        /// Default. No user content and no stable identifier (README "Privacy guarantees").
        /// Release-health sessions use an identifier that is random for each launch.
        case strict
        /// Opt-in ("Share detailed diagnostics" on and reporting on): error text, file names
        /// and paths, forwarded app logs, a stable installation identifier, sessions and
        /// metrics. Never the device name, IP address, screenshots or view hierarchy.
        case diagnostic

        /// The more private of two profiles.
        static func mostPrivate(_ lhs: Self, _ rhs: Self) -> Self {
            lhs == .diagnostic && rhs == .diagnostic ? .diagnostic : .strict
        }
    }
}
