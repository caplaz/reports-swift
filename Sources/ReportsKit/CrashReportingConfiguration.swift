import Foundation

/// Everything `CrashReporting.start` needs. Holds closures, so it is not `Equatable`.
public struct CrashReportingConfiguration: Sendable {
    /// Sentry DSN. Point its host at a reverse proxy you control (e.g.
    /// `https://<publicKey>@reports.example.com/<projectId>`) so no app traffic goes to
    /// `*.sentry.io` and the user's IP never reaches Sentry. DSN public keys are not secrets.
    public var dsn: String
    /// `<bundleID>@<version>+<build>`; see `releaseName(info:)`.
    public var releaseName: String
    /// Initial Sentry environment, set before any event can be captured.
    public var environment: String
    /// SDK cache (`Options.cacheDirectoryPath`). Deleted at launch when reporting is off.
    public var cacheDirectory: URL
    public var tracesSampleRate: Double
    /// Whether `CrashReporting.log` sends structured logs (`Options.enableLogs`). Default `true`.
    public var logsEnabled: Bool
    /// Whether `CrashReporting.count`/`distribution`/`gauge` send metrics
    /// (`Options.enableMetrics`), in both profiles. Default `true`.
    public var metricsEnabled: Bool
    /// The **only** error text that leaves the device for a handled error (`report.error`
    /// tag, exception type, fingerprint; log body and `report.error` log attribute). It must
    /// never include paths, file names, URLs, `localizedDescription`, `userInfo` values or any
    /// other user content — format only
    /// static information such as the error's type name, an allowlisted domain and numeric
    /// codes.
    public var describeError: @Sendable (any Error) -> String
    /// Resolves the real environment after start (e.g. from StoreKit's `AppTransaction`).
    /// Runs once on a detached utility task; a `nil` result keeps `environment`.
    public var environmentResolver: (@Sendable () async -> String?)?

    public init(
        dsn: String,
        releaseName: String,
        environment: String,
        cacheDirectory: URL,
        tracesSampleRate: Double = 0.05,
        logsEnabled: Bool = true,
        metricsEnabled: Bool = true,
        describeError: @escaping @Sendable (any Error) -> String,
        environmentResolver: (@Sendable () async -> String?)? = nil
    ) {
        self.dsn = dsn
        self.releaseName = releaseName
        self.environment = environment
        self.cacheDirectory = cacheDirectory
        self.tracesSampleRate = tracesSampleRate
        self.logsEnabled = logsEnabled
        self.metricsEnabled = metricsEnabled
        self.describeError = describeError
        self.environmentResolver = environmentResolver
    }

    /// Configuration with the release name read from `bundle` and the default cache
    /// directory, or `nil` when `dsn` is empty (reporting stays off).
    public static func standard(
        dsn: String,
        bundle: Bundle = .main,
        environment: String = "production",
        logsEnabled: Bool = true,
        metricsEnabled: Bool = true,
        describeError: @escaping @Sendable (any Error) -> String,
        environmentResolver: (@Sendable () async -> String?)? = nil
    ) -> CrashReportingConfiguration? {
        guard !dsn.isEmpty else { return nil }
        return CrashReportingConfiguration(
            dsn: dsn,
            releaseName: releaseName(info: bundle.infoDictionary ?? [:]),
            environment: environment,
            cacheDirectory: defaultCacheDirectory(),
            logsEnabled: logsEnabled,
            metricsEnabled: metricsEnabled,
            describeError: describeError,
            environmentResolver: environmentResolver
        )
    }

    /// `<bundleID>@<version>+<build>` — the release name sentry-cli associates dSYMs with.
    public static func releaseName(info: [String: Any]) -> String {
        let identifier = info["CFBundleIdentifier"] as? String ?? "unknown"
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(identifier)@\(version)+\(build)"
    }

    /// `Caches/CrashReporting`, app-owned so opt-out can delete it.
    public static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReporting", isDirectory: true)
    }
}
