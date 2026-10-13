import Foundation
import Sentry

/// The only entry point apps use; the only file family that imports Sentry.
public enum CrashReporting {
    /// A handled-error site. Apps declare their own:
    ///
    /// ```swift
    /// extension CrashReporting.Operation {
    ///     static let exportSave = Self("exportSave")
    /// }
    /// ```
    ///
    /// The raw value becomes the `report.op` tag and part of the fingerprint, so it must be a
    /// static identifier written in source code — never user data (file names, paths, text).
    public struct Operation: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuration: CrashReportingConfiguration?
    nonisolated(unsafe) private static var sdkStarted = false
    nonisolated(unsafe) static var preferenceDefaults: UserDefaults = .standard
    nonisolated(unsafe) static var testOptionsOverride: ((Options) -> Void)?
    nonisolated(unsafe) static var logThrottle = LogThrottle()

    /// Call first thing at launch, on the main thread. With `enabled == false` the SDK is not
    /// started and its cache — reports captured earlier but never delivered — is deleted.
    public static func start(enabled: Bool, configuration: CrashReportingConfiguration) {
        lock.withLock { Self.configuration = configuration }
        if enabled {
            startSDK(configuration)
        } else {
            ConsentGate.shared.setEnabled(false)
            try? FileManager.default.removeItem(at: configuration.cacheDirectory)
        }
    }

    /// Settings toggle. Off blocks and cancels uploads immediately and never calls
    /// `SentrySDK.close()` (it flushes). On resumes the gate or starts the SDK.
    public static func setEnabled(_ enabled: Bool) {
        CrashReportingPreference.set(enabled, in: preferenceDefaults)
        guard enabled else {
            ConsentGate.shared.setEnabled(false)
            return
        }
        let (configuration, started) = lock.withLock { (Self.configuration, sdkStarted) }
        if started {
            ConsentGate.shared.setEnabled(true)
            // The transport only drains its disk queue on a capture, a connectivity change,
            // or a flush; after a gate-refused send it stops. Kick a drain so reports queued
            // while consent was off (but collected while it was on) are delivered now.
            DispatchQueue.global(qos: .utility).async { SentrySDK.flush(timeout: 10) }
        } else if let configuration {
            startSDK(configuration)
        }
    }

    /// Reports a handled failure as `report.op` + `configuration.describeError(error)` only —
    /// never the error value, its description, or `userInfo`. A no-op before `start`, while
    /// reporting is off, or when the SDK isn't running.
    public static func capture(_ error: any Error, operation: Operation) {
        guard let configuration = lock.withLock({ Self.configuration }),
              ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return }
        SentrySDK.capture(event: makeEvent(error: error, operation: operation, describe: configuration.describeError))
    }

    /// The configuration when a log may be sent now: started, consent on, SDK running, and
    /// `logsEnabled`.
    static func canLog() -> CrashReportingConfiguration? {
        guard let configuration = lock.withLock({ Self.configuration }), configuration.logsEnabled,
              ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return nil }
        return configuration
    }

    static func makeEvent(
        error: any Error, operation: Operation, describe: (any Error) -> String
    ) -> Event {
        let description = describe(error)
        let event = Event(level: .error)
        let exception = Exception(value: CrashReportSanitizer.redacted, type: "\(operation.rawValue) \(description)")
        let mechanism = Mechanism(type: "report.handled")
        mechanism.handled = NSNumber(value: true)
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.tags = ["report.op": operation.rawValue, "report.error": description]
        event.fingerprint = ["report", operation.rawValue, description]
        return event
    }

    /// Must run on the main thread: sentry-cocoa 9.24.0 installs the hub synchronously only
    /// when started on main (off-main it dispatches the install asynchronously).
    private static func startSDK(_ configuration: CrashReportingConfiguration) {
        precondition(Thread.isMainThread, "CrashReporting must start on the main thread")
        ConsentGate.shared.setEnabled(true)
        SentrySDK.start { options in apply(configuration, to: options) }
        lock.withLock { sdkStarted = true }
        if let resolver = configuration.environmentResolver {
            Task.detached(priority: .utility) {
                guard let name = await resolver() else { return }
                SentrySDK.configureScope { $0.setEnvironment(name) }
            }
        }
    }

    static func apply(_ configuration: CrashReportingConfiguration, to options: Options) {
        options.dsn = configuration.dsn
        options.releaseName = configuration.releaseName
        options.environment = configuration.environment
        options.cacheDirectoryPath = configuration.cacheDirectory.path
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.enableAppHangTracking = true
        options.tracesSampleRate = NSNumber(value: configuration.tracesSampleRate)
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        // Default true installs SentryNetworkTrackingIntegration and swizzles URLSessionTask
        // app-wide; failed requests from the app's own URLSessions would otherwise become
        // events (with their URLs).
        options.enableCaptureFailedRequests = false
        options.sendClientReports = false
        // Metrics is a separate telemetry API (counters/gauges/measurements) that
        // CrashReporting never calls; keep it off rather than ship an unused ingestion path.
        options.enableMetrics = false
        options.enableLogs = configuration.logsEnabled
        #if os(iOS)
        // UIKit-only options in sentry-cocoa 9.24.0 (absent from the macOS slice).
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        #endif
        #if os(macOS)
        // AppKit swallows uncaught main-thread NSExceptions otherwise; Sentry recommends
        // enabling this on macOS.
        options.enableUncaughtNSExceptionReporting = true
        #endif

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ConsentURLProtocol.self]
        options.urlSession = URLSession(configuration: sessionConfiguration)

        options.beforeSend = { event in
            guard ConsentGate.shared.isEnabled else { return nil }
            return CrashReportSanitizer.sanitize(event)
        }
        options.beforeBreadcrumb = { breadcrumb in
            guard ConsentGate.shared.isEnabled else { return nil }
            return CrashReportSanitizer.sanitize(breadcrumb)
        }
        options.beforeSendLog = { log in
            guard ConsentGate.shared.isEnabled else { return nil }
            return CrashReportSanitizer.sanitize(log: log, expected: PendingLog.current)
        }
        options.beforeSendSpan = { span in
            CrashReportSanitizer.sanitize(span: span)
            return span
        }
        testOptionsOverride?(options)
    }

    /// Test-only: close the SDK and forget state. `close()` flushes, so callers must have
    /// the network stubbed.
    static func resetForTesting() {
        SentrySDK.close()
        ConsentGate.shared.setEnabled(false)
        lock.withLock {
            configuration = nil
            sdkStarted = false
        }
        testOptionsOverride = nil
        preferenceDefaults = .standard
        logThrottle = LogThrottle()
    }
}
