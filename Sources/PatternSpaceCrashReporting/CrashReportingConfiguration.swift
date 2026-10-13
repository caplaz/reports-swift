import Foundation
import PatternSpaceCore

public struct CrashReportingConfiguration: Sendable, Equatable {
    public var dsn: String
    public var releaseName: String
    public var environment: String
    public var cacheDirectory: URL
    public var tracesSampleRate: Double

    public init(
        dsn: String,
        releaseName: String,
        environment: String,
        cacheDirectory: URL,
        tracesSampleRate: Double = 0.05
    ) {
        self.dsn = dsn
        self.releaseName = releaseName
        self.environment = environment
        self.cacheDirectory = cacheDirectory
        self.tracesSampleRate = tracesSampleRate
    }

    /// DSNs use the reports.caplaz.com proxy host (caplaz/reports-proxy). DSN public keys are
    /// not secrets. Empty → reporting stays off.
    static let macOSDSN = ""
    static let iOSDSN = ""

    /// Configuration for the shipping app, or nil when no DSN is configured for this platform.
    public static func appStore(bundle: Bundle = .main) -> CrashReportingConfiguration? {
        #if os(macOS)
        let dsn = macOSDSN
        #else
        let dsn = iOSDSN
        #endif
        guard !dsn.isEmpty else { return nil }
        return CrashReportingConfiguration(
            dsn: dsn,
            releaseName: releaseName(info: bundle.infoDictionary ?? [:]),
            environment: "production",   // refined after start from AppTransaction
            cacheDirectory: defaultCacheDirectory()
        )
    }

    /// `<bundleID>@<version>+<build>` — the release name sentry-cli associates dSYMs with.
    static func releaseName(info: [String: Any]) -> String {
        let identifier = info["CFBundleIdentifier"] as? String ?? "unknown"
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(identifier)@\(version)+\(build)"
    }

    /// Sentry environment for a StoreKit environment. TestFlight installs run against the
    /// sandbox on both platforms.
    static func environmentName(for environment: EntitlementEnvironment) -> String {
        switch environment {
        case .production: "production"
        case .sandbox, .testFlight: "testflight"
        case .xcode: "development"
        }
    }

    /// SDK cache (`Options.cacheDirectoryPath`). Deleted on launch when reporting is off.
    public static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReporting", isDirectory: true)
    }
}
