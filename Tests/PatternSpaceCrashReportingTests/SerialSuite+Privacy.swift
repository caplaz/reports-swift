import Foundation
import Sentry
import Testing
@testable import PatternSpaceCrashReporting

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
            userInfo: ["path": "/Volumes/Work/x.icc"])
        SentrySDK.capture(exception: exception)
        await SDKHarness.flush()
        let envelopes = try SDKHarness.envelopes()
        let event = try #require(envelopes.flatMap(\.items).first { $0.type == "event" }?.json)
        let values = (event["exception"] as? [String: Any])?["values"] as? [[String: Any]]
        #expect(values?.first?["type"] as? String == "NSInvalidArgumentException")
        assertNoNeedles(envelopes)
    }

    @MainActor @Test func transactionKeepsSpansAndDropsPlantedDataOnRootAndChild() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let transaction = SentrySDK.startTransaction(name: "ps.test", operation: "ui.load")
        transaction.setData(value: "/Users/jane/root.cube", key: "file")
        transaction.setTag(value: "Jane", key: "who")
        let child = transaction.startChild(operation: "file.read", description: "/Users/jane/Client Smith.cube")
        child.setData(value: "/Volumes/Work/child.icc", key: "file.path")
        child.setTag(value: "secret words", key: "note")
        child.finish()
        transaction.finish()
        // Deviation from plan: `SentryTracer.finish()` dispatches the actual hub capture
        // (event build + beforeSend + envelope) asynchronously onto the hub's private queue
        // (SentryHub.m: "the calling thread here could be the main thread... capture the
        // transaction on a background thread"), so `SentrySDK.flush(timeout:)` called right
        // after `finish()` can race ahead of that dispatch and see zero pending work, returning
        // almost instantly (confirmed: without the wait below, this test fails deterministically
        // in well under the flush timeout, with `beforeSend` observed to run only afterward).
        // Plain `capture(event:)`/`capture(exception:)` do not hit this: those tests pass as
        // written. Poll (same bounded-wait idiom as Task 9's `reEnableInSessionDrainsQueue`)
        // instead of a fixed sleep so this isn't sensitive to machine speed.
        let deadline = Date().addingTimeInterval(5)
        while RecordingURLProtocol.bodies.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await SDKHarness.flush()

        let envelopes = try SDKHarness.envelopes()
        let item = try #require(envelopes.flatMap(\.items).first { $0.type == "transaction" })
        let json = try #require(item.json)
        #expect(json["transaction"] as? String == "ps.test")
        let spans = try #require(json["spans"] as? [[String: Any]])
        #expect(spans.contains { $0["op"] as? String == "file.read" })
        #expect(json["start_timestamp"] != nil)
        assertNoNeedles(envelopes)
    }

    @MainActor @Test func noUserIdentifierAndNoSessionsAcrossStarts() async throws {
        for _ in 0..<2 {
            let config = SDKHarness.reset()
            CrashReporting.start(enabled: true, configuration: config)
            CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 260), operation: .lutExportPrepare)
            await SDKHarness.flush()
            let items = try SDKHarness.envelopes().flatMap(\.items)
            #expect(!items.isEmpty)
            #expect(!items.contains { $0.type == "session" })
            for item in items where item.type == "event" {
                #expect(item.json?["user"] == nil)
            }
        }
    }
}
