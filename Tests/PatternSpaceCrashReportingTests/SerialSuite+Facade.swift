import Foundation
import Sentry
import Testing
@testable import PatternSpaceCrashReporting

extension SerialSuite {
    @MainActor @Test func startDisabledDeletesCacheAndDoesNotStartSDK() async throws {
        let config = SDKHarness.reset()
        try FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: config.cacheDirectory.appendingPathComponent("leftover"))
        CrashReporting.start(enabled: false, configuration: config)
        #expect(!SentrySDK.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: config.cacheDirectory.path))
        #expect(!ConsentGate.shared.isEnabled)
    }

    @MainActor @Test func handledErrorCarriesOnlyDescribeAndOperation() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 2,
                                 userInfo: [NSFilePathErrorKey: "/Users/jane/underlying.cube"])
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSFilePathErrorKey: "/Users/jane/Documents/Client Smith.cube",
            NSLocalizedDescriptionKey: "Jane's secret words",
            NSUnderlyingErrorKey: underlying
        ])
        CrashReporting.capture(error, operation: .lutExportSave)
        await SDKHarness.flush(until: { SDKHarness.delivered("event") })

        let envelopes = try SDKHarness.envelopes()
        let event = try #require(envelopes.flatMap(\.items).first { $0.type == "event" }?.json)
        let tags = event["tags"] as? [String: String]
        #expect(tags?["ps.op"] == "lutExportSave")
        #expect(tags?["ps.error"]?.contains("code=4") == true)
        for envelope in envelopes {
            #expect(!envelope.text.contains("jane"))
            #expect(!envelope.text.contains("Jane"))
            #expect(!envelope.text.contains("Client Smith"))
            #expect(!envelope.text.contains("secret words"))
        }
        #expect(event["user"] == nil)
    }

    @MainActor @Test func setEnabledPersistsPreference() async {
        _ = SDKHarness.reset()
        CrashReporting.setEnabled(false)
        #expect(!CrashReportingPreference.isEnabled(in: CrashReporting.preferenceDefaults))
        CrashReporting.setEnabled(true)
        #expect(CrashReportingPreference.isEnabled(in: CrashReporting.preferenceDefaults))
    }
}
