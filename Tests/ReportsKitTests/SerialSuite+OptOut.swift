import Foundation
import Sentry
import Testing
@testable import ReportsKit

extension SerialSuite {
    @MainActor private func queueOneEventOffline(_ config: CrashReportingConfiguration) async {
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        await SDKHarness.flush(until: { SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1 })
    }

    // (a) queued offline, opt out, back online, drain → nothing sent, still on disk
    @MainActor @Test func optOutBlocksQueuedEnvelopesWhenNetworkReturns() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        await queueOneEventOffline(config)
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1)
        CrashReporting.setEnabled(false)
        RecordingURLProtocol.mode = .accept
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 2), operation: .profileSave)
        await SDKHarness.flush()
        #expect(RecordingURLProtocol.bodies.isEmpty)
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1)
    }

    // (b) relaunch with preference off → SDK not started, cache deleted, nothing sent
    @MainActor @Test func relaunchWithOptOutDiscardsQueue() async {
        let config = SDKHarness.reset(mode: .failConnection)
        await queueOneEventOffline(config)
        CrashReporting.setEnabled(false)
        SentrySDK.close()                      // simulate process exit (gate is off: flush can't send)
        RecordingURLProtocol.mode = .accept
        CrashReporting.start(enabled: false, configuration: config)
        #expect(!SentrySDK.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: config.cacheDirectory.path))
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }

    // (c) admission race: paused after admission, opt out, resume → zero bytes, envelope kept
    @MainActor @Test func optOutDuringAdmittedUploadKeepsEnvelope() async {
        let config = SDKHarness.reset(mode: .pauseBeforeDelivery)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 3), operation: .deviceStart)
        #expect(await RecordingURLProtocol.waitForArrival())
        CrashReporting.setEnabled(false)
        #expect(await RecordingURLProtocol.waitForStop())   // cancellation reached the protocol
        RecordingURLProtocol.proceed.signal()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(RecordingURLProtocol.bodies.isEmpty)
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1)
    }

    // (d) re-enable in-session → previously queued envelopes delivered
    @MainActor @Test func reEnableInSessionDrainsQueue() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        await queueOneEventOffline(config)
        CrashReporting.setEnabled(false)
        RecordingURLProtocol.mode = .accept
        CrashReporting.setEnabled(true)
        // No new capture and no test-driven flush: re-enabling alone must drain the queue.
        let deadline = Date().addingTimeInterval(5)
        while RecordingURLProtocol.bodies.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let events = try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "event" }
        #expect(events.count >= 1)
    }

    // (e) re-enable after a disabled launch → SDK starts, new events delivered
    @MainActor @Test func reEnableAfterDisabledLaunchStartsSDK() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: false, configuration: config)
        CrashReporting.setEnabled(true)
        #expect(SentrySDK.isEnabled)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 6), operation: .exportSave)
        await SDKHarness.flush(until: { SDKHarness.delivered("event") })
        let delivered = try SDKHarness.envelopes().flatMap(\.items)
        #expect(delivered.contains { $0.type == "event" })
    }
}
