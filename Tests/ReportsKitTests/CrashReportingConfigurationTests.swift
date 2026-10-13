import Foundation
import Testing
@testable import ReportsKit

@Suite struct CrashReportingConfigurationTests {
    @Test func releaseNameMatchesDSYMUploadFormat() {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.MyApp",
            "CFBundleShortVersionString": "2.3",
            "CFBundleVersion": "417"
        ]
        #expect(CrashReportingConfiguration.releaseName(info: info) == "com.example.MyApp@2.3+417")
    }

    @Test func releaseNameFallsBackForMissingKeys() {
        #expect(CrashReportingConfiguration.releaseName(info: [:]) == "unknown@0+0")
    }

    @Test func cacheDirectoryIsAppOwned() {
        #expect(CrashReportingConfiguration.defaultCacheDirectory().lastPathComponent == "CrashReporting")
    }

    @Test func defaultSampleRateIsFivePercent() {
        let config = CrashReportingConfiguration(
            dsn: "https://k@reports.example.com/1", releaseName: "r", environment: "e",
            cacheDirectory: URL(fileURLWithPath: "/tmp/x"), describeError: TestErrors.describe)
        #expect(config.tracesSampleRate == 0.05)
        #expect(config.environmentResolver == nil)
    }

    @Test func standardIsNilForAnEmptyDSN() {
        #expect(CrashReportingConfiguration.standard(dsn: "", describeError: TestErrors.describe) == nil)
    }

    @Test func standardFillsReleaseCacheAndEnvironment() throws {
        let config = try #require(CrashReportingConfiguration.standard(
            dsn: "https://k@reports.example.com/1", describeError: TestErrors.describe))
        #expect(config.dsn == "https://k@reports.example.com/1")
        #expect(config.environment == "production")
        #expect(config.cacheDirectory == CrashReportingConfiguration.defaultCacheDirectory())
        #expect(config.releaseName == CrashReportingConfiguration.releaseName(info: Bundle.main.infoDictionary ?? [:]))
        #expect(config.tracesSampleRate == 0.05)
        #expect(config.describeError(NSError(domain: NSCocoaErrorDomain, code: 4)).contains("code=4"))
    }
}
