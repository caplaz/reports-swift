import Foundation
import Sentry
import Testing
@testable import ReportsKit

/// Turning "Share detailed diagnostics" off applies in-process (owner decision, review fix 4);
/// turning it on applies at the next SDK start.
extension SerialSuite {
    private static let plantedID = "stable-installation-id"

    /// A second diagnostic launch (stable planted installation ID), app inactive.
    @MainActor private static func startDiagnosticLaunch() throws -> CrashReportingConfiguration {
        let config = SDKHarness.reset()
        try FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        try Data(plantedID.utf8).write(to: config.cacheDirectory.appendingPathComponent(CrashReporting.installationFileName))
        CrashReportingPreference.setLastProfile(.diagnostic, in: CrashReporting.preferenceDefaults)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        // Caches the installation ID in memory now, so logs carry `user.id` (as in
        // SerialSuite+Forwarding).
        SentrySDK.startSession()
        return config
    }

    private static func offEvents() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "event" }.compactMap(\.json)
    }

    private static func offLogs() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "log" }
            .flatMap { ($0.json?["items"] as? [[String: Any]]) ?? [] }
    }

    private static func offExceptionValue(_ event: [String: Any]) -> String? {
        (((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)?["value"] as? String
    }

    private static func pathError(_ code: Int) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code, userInfo: [NSFilePathErrorKey: "/Users/jane/Client Smith.cube"])
    }

    @MainActor @Test func detailedOffDowngradesTheProcessUntilTheNextStart() async throws {
        _ = try Self.startDiagnosticLaunch()
        #expect(CrashReporting.activeProfile == .diagnostic)
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        #expect(CrashReporting.activeProfile == .strict)
        var tag: String?
        SentrySDK.configureScope { tag = $0.tags[CrashReportSanitizer.profileTagKey] }
        #expect(tag == "strict")                       // crash reports collected from now on
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        #expect(CrashReporting.activeProfile == .strict)    // on: only at the next start
        #expect(CrashReportingPreference.isDetailedDiagnosticsEnabled(in: CrashReporting.preferenceDefaults))
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func detailedOffStripsErrorTextUserAndBreadcrumbMessagesFromEvents() async throws {
        _ = try Self.startDiagnosticLaunch()
        let early = Breadcrumb(level: .info, category: "ui")       // kept as diagnostic at add time
        early.message = "/Users/jane/early"
        SentrySDK.addBreadcrumb(early)
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        let late = Breadcrumb(level: .info, category: "ui")
        late.message = "/Users/jane/late"
        SentrySDK.addBreadcrumb(late)
        CrashReporting.capture(Self.pathError(1), operation: .exportSave)          // ReportsKit event
        let live = Event(level: .error)                                             // SDK-style event
        live.exceptions = [Exception(value: "/Users/jane/live", type: "NSInvalidArgumentException")]
        SentrySDK.capture(event: live)
        // Collected under diagnostic by an earlier launch, replayed without the current scope
        // (as the SDK replays stored crashes): its own tag says diagnostic, the setting wins.
        let replayed = Event(level: .fatal)
        replayed.exceptions = [Exception(value: "/Users/jane/replayed", type: "EXC_BAD_ACCESS")]
        replayed.tags = ["report.profile": "diagnostic"]
        SentrySDK.capture(event: replayed, scope: Scope())
        #expect(await SDKHarness.flush(until: { ((try? Self.offEvents().count) ?? 0) >= 3 }))
        let events = try Self.offEvents()
        #expect(events.count == 3)
        for event in events {
            #expect(Self.offExceptionValue(event) == "<redacted>")
            #expect(event["user"] == nil)
            #expect((event["tags"] as? [String: String])?["report.profile"] == "strict")
        }
        let text = try SDKHarness.envelopes().filter { $0.items.contains { $0.type == "event" } }
            .map(\.text).joined()
        #expect(!text.contains("/Users/jane"))
        #expect(!text.contains(Self.plantedID))
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func detailedOffStopsForwardingAndStripsLogDetailAndUserID() async throws {
        _ = try Self.startDiagnosticLaunch()
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        CrashReporting.forwardLog(.error, category: "SDI", message: "must not leave")
        CrashReporting.log(.error, Self.pathError(2), operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        await SDKHarness.flush()
        let logs = try Self.offLogs()
        #expect(logs.compactMap { $0["body"] as? String } == ["profileSave NSError code=2"])
        let attributes = (logs.first?["attributes"] as? [String: Any]) ?? [:]
        #expect(attributes["report.error.detail"] == nil)
        #expect(attributes["user.id"] == nil)
        #expect(Set(attributes.keys).isSubset(of: CrashReportSanitizer.allowedLogAttributeKeys(.strict)))
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    // A forwarded line admitted before the switch but emitted after it is dropped too.
    @MainActor @Test func forwardedLineQueuedBeforeDetailedOffIsNotSent() async throws {
        _ = try Self.startDiagnosticLaunch()
        CrashReporting.forwardQueue.suspend()
        CrashReporting.forwardLog(.error, category: "SDI", message: "queued before off")
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        CrashReporting.forwardQueue.resume()
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        await SDKHarness.flush()
        #expect(try Self.offLogs().compactMap { $0["body"] as? String } == ["sentinel"])
        SentrySDK.endSession()
        await SDKHarness.flush()
    }
}
