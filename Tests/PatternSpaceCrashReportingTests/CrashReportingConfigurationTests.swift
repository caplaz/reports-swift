import Foundation
import Testing
@testable import PatternSpaceCrashReporting

@Suite struct CrashReportingConfigurationTests {
    @Test func releaseNameMatchesDSYMUploadFormat() {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.caplaz.PatternSpace",
            "CFBundleShortVersionString": "2.3",
            "CFBundleVersion": "417"
        ]
        #expect(CrashReportingConfiguration.releaseName(info: info) == "com.caplaz.PatternSpace@2.3+417")
    }

    @Test func environmentNameFromStoreKitEnvironment() {
        #expect(CrashReportingConfiguration.environmentName(for: .sandbox) == "testflight")
        #expect(CrashReportingConfiguration.environmentName(for: .testFlight) == "testflight")
        #expect(CrashReportingConfiguration.environmentName(for: .production) == "production")
        #expect(CrashReportingConfiguration.environmentName(for: .xcode) == "development")
    }

    // `EntitlementEnvironment.current()` returns `.xcode` both for a genuine Xcode-run app
    // and for a lookup failure (no verified AppTransaction, or the lookup throwing), and
    // crash reporting only ever starts in Release builds (CrashReportingBootstrap is
    // `#if !DEBUG`), so a `.xcode` result there is overwhelmingly a lookup failure. The
    // resolver must not use it to downgrade a real production/TestFlight user to
    // "development" — it returns nil (keep the initial environment) instead.
    @Test func resolvedEnvironmentOverrideKeepsInitialEnvironmentOnXcodeResult() {
        #expect(CrashReportingConfiguration.resolvedEnvironmentOverride(for: .xcode) == nil)
    }

    @Test func resolvedEnvironmentOverrideMatchesEnvironmentNameOtherwise() {
        #expect(CrashReportingConfiguration.resolvedEnvironmentOverride(for: .production) == "production")
        #expect(CrashReportingConfiguration.resolvedEnvironmentOverride(for: .sandbox) == "testflight")
        #expect(CrashReportingConfiguration.resolvedEnvironmentOverride(for: .testFlight) == "testflight")
    }

    @Test func cacheDirectoryIsAppOwned() {
        #expect(CrashReportingConfiguration.defaultCacheDirectory().lastPathComponent == "CrashReporting")
    }

    @Test func defaultSampleRateIsFivePercent() {
        let config = CrashReportingConfiguration(
            dsn: "https://k@reports.caplaz.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"))
        #expect(config.tracesSampleRate == 0.05)
    }

    // The constants are empty placeholders until the real DSNs are filled in; once they are,
    // this catches a DSN pasted from Sentry's own dashboard (*.ingest.*.sentry.io) instead of
    // the reports.caplaz.com proxy.
    @Test func dsnConstantsRouteThroughTheReportsProxyHost() {
        for dsn in [CrashReportingConfiguration.macOSDSN, CrashReportingConfiguration.iOSDSN] where !dsn.isEmpty {
            #expect(URL(string: dsn)?.host == "reports.caplaz.com")
        }
    }
}
