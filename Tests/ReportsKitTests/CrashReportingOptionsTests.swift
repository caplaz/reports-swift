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
}
