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
        #expect(tags?["report.op"] == "exportSave")
        #expect(tags?["report.error"]?.contains("code=4") == true)
        let exception = ((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first
        #expect((exception?["mechanism"] as? [String: Any])?["type"] as? String == "report.handled")
        #expect((event["fingerprint"] as? [String])?.first == "report")
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

    @MainActor @Test func screenBreadcrumbsReachAnEventAsNameOnly() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        // The SDK and the consent gate may still be starting; a screen marked before both are on is not recorded.
        let deadline = Date().addingTimeInterval(5)
        while !(SentrySDK.isEnabled && ConsentGate.shared.isEnabled), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        SentrySDK.configureScope { $0.clearBreadcrumbs() }
        CrashReporting.screen(.init("home"))
        CrashReporting.screen(.init("scan.check"))
        // A breadcrumb with a message and extra data, as an app could add through the SDK directly.
        let stray = Breadcrumb(level: .info, category: "screen")
        stray.message = "Jane's bill 86.40"
        stray.setData(value: "Jane's bill 86.40", key: "title")
        SentrySDK.addBreadcrumb(stray)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 4301), operation: .exportSave)
        let envelopes = try SDKHarness.envelopes()
        let event = try #require(await eventWithCode(4301))
        let crumbs = try #require(event["breadcrumbs"] as? [[String: Any]])
        let named = crumbs.compactMap { ($0["data"] as? [String: Any])?["screen"] as? String }
        #expect(named == ["home", "scan.check"], "\(crumbs)")
        for crumb in crumbs {
            #expect(crumb["message"] == nil)
            #expect(Set((crumb["data"] as? [String: Any] ?? [:]).keys).isSubset(of: ["screen", "state"]))
        }
        for envelope in envelopes {
            #expect(!envelope.text.contains("Jane"))
            #expect(!envelope.text.contains("86.40"))
        }
    }

    @MainActor @Test func screenBeforeStartOrWhileOptedOutRecordsNothing() async throws {
        let config = SDKHarness.reset()
        CrashReporting.screen(.init("home"))
        CrashReporting.start(enabled: false, configuration: config)
        CrashReporting.screen(.init("settings"))
        #expect(!SentrySDK.isEnabled)
    }

    @Test func theTrailKeepsTheLastTwenty() {
        #expect(CrashReporting.maxBreadcrumbs == 20)
    }

    /// The delivered event of this test, found by its error code: an envelope of an earlier test can still
    /// arrive late, and a flush that sees any event is not a barrier for this one.
    @MainActor private func eventWithCode(_ code: Int) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            await SDKHarness.flush()
            let events = (try? SDKHarness.envelopes())?.flatMap(\.items) ?? []
            if let found = events.first(where: { ($0.json?["tags"] as? [String: String])?["report.error"]?.contains("code=\(code)") == true })?.json { return found }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }
}
