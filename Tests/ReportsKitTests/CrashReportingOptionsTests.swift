import Foundation
import Sentry
import Testing
@testable import ReportsKit

/// Asserts the hardened SDK option values `CrashReporting.apply` sets, independent of the
/// consent/transport path exercised elsewhere. `apply` only mutates the `Options` instance
/// it's given, so this runs against a fresh `Options()` and doesn't touch `SentrySDK` state.
@Suite struct CrashReportingOptionsTests {
    @Test func hardensNetworkAndClientReportOptions() {
        let configuration = CrashReportingConfiguration(
            dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"), describeError: TestErrors.describe)
        let options = Options()
        CrashReporting.apply(configuration, to: options)

        // Default true installs SentryNetworkTrackingIntegration and swizzles
        // URLSessionTask app-wide; would turn the app's own failed requests (with their
        // URLs) into events.
        #expect(options.enableCaptureFailedRequests == false)
        #expect(options.sendClientReports == false)
        // Metrics in both profiles, gated by beforeSendMetric (spec 2026-10-17 §4).
        #expect(options.enableMetrics == true)
        #expect(options.beforeSendMetric != nil)
        // Room for offline metric batches without evicting queued reports (spec §6).
        #expect(options.maxCacheItems == 100)
    }

    @Test func mapsLogsEnabledToEnableLogsAndInstallsBeforeSendLog() {
        for enabled in [true, false] {
            let configuration = CrashReportingConfiguration(
                dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
                cacheDirectory: URL(fileURLWithPath: "/tmp/x"), logsEnabled: enabled,
                describeError: TestErrors.describe)
            let options = Options()
            CrashReporting.apply(configuration, to: options)
            #expect(options.enableLogs == enabled)
            #expect(options.beforeSendLog != nil)
        }
    }

    #if os(macOS)
    @Test func enablesUncaughtNSExceptionReportingOnMacOS() {
        let configuration = CrashReportingConfiguration(
            dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"), describeError: TestErrors.describe)
        let options = Options()
        CrashReporting.apply(configuration, to: options)
        // AppKit otherwise swallows uncaught main-thread NSExceptions; Sentry recommends this.
        #expect(options.enableUncaughtNSExceptionReporting == true)
    }
    #endif

    private static func configuration() -> CrashReportingConfiguration {
        CrashReportingConfiguration(
            dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"), describeError: TestErrors.describe)
    }

    @Test func strictEnablesSessionsAndGatedMetrics() {
        let options = Options()
        CrashReporting.apply(Self.configuration(), to: options)
        #expect(options.enableAutoSessionTracking == false)   // ConsentSessionTracker drives sessions
        #expect(options.enableMetrics == true)
        #expect(options.beforeSendMetric != nil)
        #expect(options.sendDefaultPii == false)
        // Collection-time marker: on the scope before any integration installs.
        #expect(options.initialScope(Scope()).tags == ["report.profile": "strict"])
    }

    @Test func diagnosticEnablesSessionsAndGatedMetrics() {
        let options = Options()
        CrashReporting.apply(Self.configuration(), profile: .diagnostic, to: options)
        #expect(options.enableAutoSessionTracking == false)
        #expect(options.enableMetrics == true)
        #expect(options.beforeSendMetric != nil)
        #expect(options.sendDefaultPii == false)
        #expect(options.initialScope(Scope()).tags == ["report.profile": "diagnostic"])
        #expect(options.enableCaptureFailedRequests == false)
        #if os(iOS)
        #expect(options.attachScreenshot == false)
        #expect(options.attachViewHierarchy == false)
        #endif
    }

    @Test func metricsEnabledFalseTurnsTheIntegrationOff() {
        for profile in CrashReporting.PrivacyProfile.allCases {
            let configuration = CrashReportingConfiguration(
                dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
                cacheDirectory: URL(fileURLWithPath: "/tmp/x"), metricsEnabled: false,
                describeError: TestErrors.describe)
            let options = Options()
            CrashReporting.apply(configuration, profile: profile, to: options)
            #expect(options.enableMetrics == false)
        }
    }

    @Test func metricsAreEnabledByDefault() {
        #expect(Self.configuration().metricsEnabled)
    }
}
