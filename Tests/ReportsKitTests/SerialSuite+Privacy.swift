import Foundation
import Sentry
import Testing
@testable import ReportsKit

extension SerialSuite {
    private static let needles = ["jane", "Jane", "Client Smith", "jane@example.com", "secret words", "/Users/", "/Volumes/"]

    private func assertNoNeedles(_ envelopes: [Envelope]) {
        for envelope in envelopes {
            for needle in Self.needles {
                #expect(!envelope.text.contains(needle), "leaked \(needle)")
            }
        }
    }

    @MainActor @Test func exceptionReasonNeverLeavesDevice() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let exception = NSException(
            name: .invalidArgumentException,
            reason: "/Users/jane/Documents/Client Smith jane@example.com secret words",
            userInfo: ["path": "/Volumes/Work/x.profile"])
        SentrySDK.capture(exception: exception)
        await SDKHarness.flush(until: { SDKHarness.delivered("event") })
        let envelopes = try SDKHarness.envelopes()
        let event = try #require(envelopes.flatMap(\.items).first { $0.type == "event" }?.json)
        let values = (event["exception"] as? [String: Any])?["values"] as? [[String: Any]]
        #expect(values?.first?["type"] as? String == "NSInvalidArgumentException")
        assertNoNeedles(envelopes)
    }

    @MainActor @Test func transactionKeepsSpansAndDropsPlantedDataOnRootAndChild() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let transaction = SentrySDK.startTransaction(name: "report.test", operation: "ui.load")
        transaction.setData(value: "/Users/jane/root.cube", key: "file")
        transaction.setTag(value: "Jane", key: "who")
        let child = transaction.startChild(operation: "file.read", description: "/Users/jane/Client Smith.cube")
        child.setData(value: "/Volumes/Work/child.profile", key: "file.path")
        child.setTag(value: "secret words", key: "note")
        child.finish()
        transaction.finish()
        // `SentryTracer.finish()` dispatches the hub capture (event build + beforeSend +
        // envelope) asynchronously onto the hub's private queue, so a flush right after
        // `finish()` can see zero pending work. `flush(until:)` also covers the transport's
        // lost-wakeup race that affects every capture (see `SDKHarness.flush(until:)`).
        await SDKHarness.flush(until: { SDKHarness.delivered("transaction") })

        let envelopes = try SDKHarness.envelopes()
        let item = try #require(envelopes.flatMap(\.items).first { $0.type == "transaction" })
        let json = try #require(item.json)
        #expect(json["transaction"] as? String == "report.test")
        let spans = try #require(json["spans"] as? [[String: Any]])
        #expect(spans.contains { $0["op"] as? String == "file.read" })
        #expect(json["start_timestamp"] != nil)
        assertNoNeedles(envelopes)
    }

    @MainActor @Test func noUserIdentifierAcrossStarts() async throws {
        for _ in 0..<2 {
            let config = SDKHarness.reset()
            CrashReporting.start(enabled: true, configuration: config)
            CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 260), operation: .exportPrepare)
            await SDKHarness.flush(until: { SDKHarness.delivered("event") })
            let items = try SDKHarness.envelopes().flatMap(\.items)
            #expect(!items.isEmpty)
            for item in items where item.type == "event" {
                #expect(item.json?["user"] == nil)
            }
        }
    }
}
