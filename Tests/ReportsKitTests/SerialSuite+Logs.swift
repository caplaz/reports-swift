import Foundation
import Sentry
import Testing
@testable import ReportsKit

/// Error whose own text is full of user data; only `describeError` may leave the device.
private struct LeakyError: LocalizedError, CustomStringConvertible {
    var description: String { "/Users/jane/Documents/Client Smith.cube jane@example.com secret words" }
    var errorDescription: String? { description }
    var failureReason: String? { "/Volumes/Work/x.profile" }
}

extension SerialSuite {
    private static var logNeedles: [String] {
        var needles = [
            "jane", "Jane", "Client Smith", "secret words", "/Users/", "/Volumes/", "/private/",
            "Caches", "CrashReportingTests-"
        ]
        // The computer name (`device.name` in event contexts). Skip implausibly short ones
        // that could collide with allowlisted values such as "Mac".
        #if os(macOS)
        if let name = Host.current().localizedName, name.count >= 8 { needles.append(name) }
        #endif
        return needles
    }

    private static func logItems() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "log" }
            .flatMap { ($0.json?["items"] as? [[String: Any]]) ?? [] }
    }

    private static func attributeValues(_ log: [String: Any]) -> [String: String] {
        let attributes = log["attributes"] as? [String: [String: Any]] ?? [:]
        return attributes.compactMapValues { $0["value"] as? String }
    }

    @MainActor @Test func errorLogSendsOnlyAllowlistedData() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: "jane"))
            scope.setAttribute(value: "/Users/jane/x", key: "file.path")
        }
        CrashReporting.log(.error, LeakyError(), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))

        let logs = try Self.logItems()
        let log = try #require(logs.first)
        #expect(logs.count == 1)
        #expect(log["body"] as? String == "exportSave LeakyError code=1")
        #expect(log["level"] as? String == "error")
        let attributes = Self.attributeValues(log)
        #expect(attributes["report.op"] == "exportSave")
        #expect(attributes["report.error"] == "LeakyError code=1")
        #expect(attributes["report.source"] == "reportskit")
        #expect(attributes["sentry.release"] == "com.example.Test@1.0+1")
        #expect(attributes["sentry.environment"] == "test")
        let keys = Set((log["attributes"] as? [String: Any] ?? [:]).keys)
        #expect(keys.isSubset(of: CrashReportSanitizer.allowedLogAttributeKeys))
        #expect(!keys.contains { $0.hasPrefix("user.") })

        for envelope in try SDKHarness.envelopes() {
            for needle in Self.logNeedles {
                #expect(!envelope.text.contains(needle), "leaked \(needle)")
            }
        }
    }

    @MainActor @Test func messageLogSendsTheStaticMessage() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.log(.warning, "Falling back to software rendering", operation: .deviceStart)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        let log = try #require(try Self.logItems().first)
        #expect(log["body"] as? String == "Falling back to software rendering")
        #expect(log["level"] as? String == "warn")
        #expect(Self.attributeValues(log)["report.op"] == "deviceStart")
        #expect(Self.attributeValues(log)["report.error"] == nil)
    }

    @MainActor @Test func logsBypassingReportsKitAreDropped() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        SentrySDK.logger.error("opened /Users/jane/Client Smith.cube")
        SentrySDK.logger.error("forged", attributes: ["report.source": "reportskit", "report.op": "exportSave"])
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        let bodies = try Self.logItems().compactMap { $0["body"] as? String }
        #expect(bodies == ["sentinel"])
    }

    @MainActor @Test func identicalLogsAreThrottled() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        for _ in 0..<5 { CrashReporting.log(.error, "repeated", operation: .exportSave) }
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await SDKHarness.flush(until: { (try? Self.logItems().count) ?? 0 >= 2 }))
        let bodies = try Self.logItems().compactMap { $0["body"] as? String }
        #expect(bodies.sorted() == ["repeated", "sentinel"])
    }

    @MainActor @Test func optOutBlocksBufferedLogsOnTheWire() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.log(.error, NSError(domain: NSCocoaErrorDomain, code: 7), operation: .exportSave)
        // The log passed beforeSendLog and sits in the SDK's batch buffer; opt out before it
        // is forwarded to the transport.
        CrashReporting.setEnabled(false)
        CrashReporting.log(.error, NSError(domain: NSCocoaErrorDomain, code: 8), operation: .exportSave)
        // Flushing forwards the buffer to the transport, which stores the envelope and is then
        // refused by the consent gate.
        #expect(await SDKHarness.flush(until: { SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1 }))
        await SDKHarness.flush()
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }

    @MainActor @Test func beforeSendLogDropsEverythingWhileGateIsClosed() throws {
        let config = SDKHarness.reset()
        let options = Options()
        CrashReporting.apply(config, to: options)
        let beforeSendLog = try #require(options.beforeSendLog)
        let expected = CrashReporting.makeLog(.error, message: "x", operation: .exportSave)
        func emitted() -> SentryLog {
            SentryLog(level: expected.level, body: expected.body,
                      attributes: expected.attributes.mapValues { SentryAttribute(string: $0) })
        }
        ConsentGate.shared.setEnabled(true)
        #expect(PendingLog.with(expected) { beforeSendLog(emitted()) } != nil)
        ConsentGate.shared.setEnabled(false)
        #expect(PendingLog.with(expected) { beforeSendLog(emitted()) } == nil)
    }

    @MainActor @Test func logIsANoOpWhileOptedOut() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        CrashReporting.log(.error, "while off", operation: .exportSave)
        CrashReporting.setEnabled(true)
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        let bodies = try Self.logItems().compactMap { $0["body"] as? String }
        #expect(bodies == ["sentinel"])
    }

    @MainActor @Test func logsDisabledSendsNoLogs() async throws {
        var config = SDKHarness.reset()
        config.logsEnabled = false
        let options = Options()
        CrashReporting.apply(config, to: options)
        #expect(options.enableLogs == false)

        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.log(.error, NSError(domain: NSCocoaErrorDomain, code: 9), operation: .exportSave)
        SentrySDK.logger.error("direct")
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 10), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        await SDKHarness.flush()
        #expect(!SDKHarness.delivered("log"))
    }

    /// sentry-cocoa 9.24.0's log scope applier sets a log's `sentry.environment` from
    /// `Options.environment` captured at `start`, not from the scope — so a resolved
    /// `environmentResolver` name (which events pick up via `configureScope`) would otherwise
    /// never reach logs. Regression test for that gap.
    @MainActor @Test func errorLogEnvironmentUsesTheResolvedEnvironmentNotTheStartupOne() async throws {
        let config = SDKHarness.reset(environmentResolver: { "testflight" })
        CrashReporting.start(enabled: true, configuration: config)
        // The resolver runs on a detached task after start and applies to the scope
        // asynchronously; bounded-poll via a capture (as SerialSuite+Facade does) until an
        // event shows the resolved environment, confirming the scope has caught up, before
        // emitting the log under test.
        let deadline = Date().addingTimeInterval(5)
        var environment: String?
        repeat {
            CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 11), operation: .exportSave)
            await SDKHarness.flush(until: { SDKHarness.delivered("event") })
            environment = try SDKHarness.envelopes().flatMap(\.items)
                .last { $0.type == "event" }?.json?["environment"] as? String
        } while environment != "testflight" && Date() < deadline
        #expect(environment == "testflight")

        CrashReporting.log(.error, "sentinel", operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        let log = try #require(try Self.logItems().first)
        #expect(Self.attributeValues(log)["sentry.environment"] == "testflight")
    }

    @MainActor @Test func logBeforeStartIsANoOp() {
        _ = SDKHarness.reset()
        CrashReporting.log(.error, "early", operation: .exportSave)
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }
}
