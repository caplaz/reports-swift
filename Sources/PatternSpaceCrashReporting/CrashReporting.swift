import Foundation
import PatternSpaceCore
import Sentry

/// The only entry point the apps use; the only file family that imports Sentry (spec §2).
public enum CrashReporting {
    /// Closed set of handled-error sites. Raw values become the `ps.op` tag.
    public enum Operation: String, Sendable {
        case lutExportPrepare
        case lutExportSave
        case iccExportSave
        case iccProfileExport
        case decklinkStart
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuration: CrashReportingConfiguration?
    nonisolated(unsafe) private static var sdkStarted = false
    nonisolated(unsafe) static var preferenceDefaults: UserDefaults = .standard
    nonisolated(unsafe) static var testOptionsOverride: ((Options) -> Void)?

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

    /// Reports a handled failure as `ps.op` + `PatternSpaceLog.describe(error)` only — never
    /// the error value, its description, or `userInfo`.
    public static func capture(_ error: any Error, operation: Operation) {
        guard ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return }
        SentrySDK.capture(event: makeEvent(error: error, operation: operation))
    }

    static func makeEvent(error: any Error, operation: Operation) -> Event {
        let description = PatternSpaceLog.describe(error)
        let event = Event(level: .error)
        let exception = Exception(value: CrashReportSanitizer.redacted, type: "\(operation.rawValue) \(description)")
        let mechanism = Mechanism(type: "ps.handled")
        mechanism.handled = NSNumber(value: true)
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.tags = ["ps.op": operation.rawValue, "ps.error": description]
        event.fingerprint = ["ps", operation.rawValue, description]
        return event
    }

    /// Resolves the real environment after start; tests replace it with nil (no StoreKit).
    nonisolated(unsafe) static var environmentResolver: (@Sendable () async -> String)? = {
        CrashReportingConfiguration.environmentName(for: await EntitlementEnvironment.current())
    }

    /// Must run on the main thread: sentry-cocoa 9.24.0 installs the hub synchronously only
    /// when started on main (off-main it dispatches the install asynchronously).
    private static func startSDK(_ configuration: CrashReportingConfiguration) {
        precondition(Thread.isMainThread, "CrashReporting must start on the main thread")
        ConsentGate.shared.setEnabled(true)
        SentrySDK.start { options in apply(configuration, to: options) }
        lock.withLock { sdkStarted = true }
        if let resolver = environmentResolver {
            Task.detached(priority: .utility) {
                let name = await resolver()
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
        // app-wide; failed requests from the app's own URLSessions (e.g. the contact form)
        // would otherwise become events.
        options.enableCaptureFailedRequests = false
        options.sendClientReports = false
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
        environmentResolver = nil
    }
}
