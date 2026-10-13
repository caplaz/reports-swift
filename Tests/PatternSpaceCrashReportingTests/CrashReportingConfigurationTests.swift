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

    @Test func cacheDirectoryIsAppOwned() {
        #expect(CrashReportingConfiguration.defaultCacheDirectory().lastPathComponent == "CrashReporting")
    }

    @Test func defaultSampleRateIsFivePercent() {
        let config = CrashReportingConfiguration(
            dsn: "https://k@reports.caplaz.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"))
        #expect(config.tracesSampleRate == 0.05)
    }
}
