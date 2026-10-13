import Foundation
import Sentry
import Testing
@testable import ReportsKit

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
        CrashReporting.capture(error, operation: .exportSave)
        await SDKHarness.flush(until: { SDKHarness.delivered("event") })

        let envelopes = try SDKHarness.envelopes()
        let event = try #require(envelopes.flatMap(\.items).first { $0.type == "event" }?.json)
        let tags = event["tags"] as? [String: String]
        #expect(tags?["ps.op"] == "exportSave")
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

    @MainActor @Test func captureBeforeStartIsANoOp() async {
        _ = SDKHarness.reset()
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 7), operation: .exportSave)
        await SDKHarness.flush()
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }

    @MainActor @Test func environmentResolverResultReplacesInitialEnvironment() async throws {
        let config = SDKHarness.reset(environmentResolver: { "staging" })
        CrashReporting.start(enabled: true, configuration: config)
        // The resolver runs on a detached task after start; capture until an event
        // carries the resolved environment (or time out).
        let deadline = Date().addingTimeInterval(5)
        var environment: String?
        repeat {
            CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 8), operation: .exportSave)
            await SDKHarness.flush(until: { SDKHarness.delivered("event") })
            environment = try SDKHarness.envelopes().flatMap(\.items)
                .last { $0.type == "event" }?.json?["environment"] as? String
        } while environment != "staging" && Date() < deadline
        #expect(environment == "staging")
    }

    @MainActor @Test func nilEnvironmentResolverResultKeepsInitialEnvironment() async throws {
        let ran = ResolverFlag()
        let config = SDKHarness.reset(environmentResolver: { ran.set(); return nil })
        CrashReporting.start(enabled: true, configuration: config)
        let deadline = Date().addingTimeInterval(5)
        while !ran.value, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ran.value)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 9), operation: .exportSave)
        await SDKHarness.flush(until: { SDKHarness.delivered("event") })
        let event = try #require(SDKHarness.envelopes().flatMap(\.items).first { $0.type == "event" }?.json)
        #expect(event["environment"] as? String == "test")
    }
}

private final class ResolverFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
