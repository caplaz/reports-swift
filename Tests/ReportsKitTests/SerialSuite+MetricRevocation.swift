import Foundation
@_spi(Private) import Sentry
import Testing
@testable import ReportsKit

/// Decision 9 (spec §4.2): metrics recorded before an opt-out are deleted, never delivered.
extension SerialSuite {
    /// SDK envelope files under `cache` holding an item of `type` (spec §2.5.3 layout).
    static func envelopeFiles(in cache: URL, containing type: String) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.deletingLastPathComponent().lastPathComponent == "envelopes",
                  let data = try? Data(contentsOf: url), let envelope = try? Envelope(data),
                  envelope.items.contains(where: { $0.type == type }) else { continue }
            files.append(url)
        }
        return files
    }

    private static func deliveredLevels() throws -> [String] {
        try metricItems().compactMap { metricStrings($0)["level"] }
    }

    @MainActor @Test func metricBufferedBeforeOptOutIsNeverDeliveredAfterReEnable() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.metricQueue.sync {}   // passed beforeSendMetric: in the SDK's 5 s buffer
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        CrashReporting.count(.testCount, attributes: ["level": "critical"])
        #expect(await Self.waitForMetrics(1))
        // Every metric envelope is gone (delivered, deleted or swallowed) before asserting.
        #expect(await SDKHarness.flush(until: {
            Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
        }))
        #expect(try Self.deliveredLevels() == ["critical"])
    }

    @MainActor @Test func metricEnvelopeOnDiskIsDeletedAtOptOut() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.metricQueue.sync {}
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        #expect(await SDKHarness.flush(until: {
            !Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
                && !Self.envelopeFiles(in: config.cacheDirectory, containing: "event").isEmpty
        }))
        CrashReporting.setEnabled(false)
        // Deleted by the opt-out itself; the queued event is kept (existing rule).
        #expect(Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty)
        #expect(!Self.envelopeFiles(in: config.cacheDirectory, containing: "event").isEmpty)
        #expect(CrashReportingPreference.hasPendingMetricSweep(in: CrashReporting.preferenceDefaults))
        RecordingURLProtocol.mode = .accept
        CrashReporting.setEnabled(true)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        #expect(!SDKHarness.delivered("trace_metric"))
    }

    @MainActor @Test func preCutoffMetricBatchIsSwallowedOnTheWire() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])   // last issued ≈ now
        CrashReporting.metricQueue.sync {}
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        // As if the opt-out's forced batch were written only now (async store, spec §2.5.2).
        PrivateSentrySDKOnly.capture(MetricRevocationTests.metricEnvelope(
            timestamp: Date().addingTimeInterval(-60), name: "planted"))
        CrashReporting.count(.testCount, attributes: ["level": "critical"])
        #expect(await Self.waitForMetrics(1))
        #expect(await SDKHarness.flush(until: {
            Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
        }))   // the swallowed batch was deleted by the transport (synthetic 200)
        let delivered = try Self.metricItems()
        #expect(!delivered.contains { $0["name"] as? String == "planted" })
        #expect(try Self.deliveredLevels() == ["critical"])
    }

    /// Blocking wait off the main thread (see `RecordingURLProtocol.waitForArrival`).
    private static func wait(_ semaphore: DispatchSemaphore, seconds: Double = 10) async -> Bool {
        await Task.detached {
            DispatchQueue.global().sync { semaphore.wait(timeout: .now() + seconds) == .success }
        }.value
    }

    /// Review finding (wire revocation vs admission): a request whose verdict was `.forward`
    /// before an opt-out must not be admitted on that verdict after the re-enable. Paused right
    /// after the verdict through the seam, then opt-out + re-enable, then resumed: the gate
    /// reports the verdict stale, the request is decided again (now `.swallow`) and answered
    /// with the synthetic 200, never forwarded.
    @MainActor @Test func optOutBetweenWireVerdictAndAdmissionIsDecidedAgain() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])   // issues a timestamp: the opt-out sets a cutoff
        CrashReporting.metricQueue.sync {}
        // A metric batch older than that timestamp, reaching ConsentURLProtocol before any opt-out.
        let body = try MetricRevocationTests.body(MetricRevocationTests.metricEnvelope(
            timestamp: Date().addingTimeInterval(-60), name: "planted"))
        let verdicts = Locked<[MetricRevocation.Verdict]>([])
        let reached = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        ConsentURLProtocol.afterVerdictForTesting = { seen, verdict in
            guard seen == body else { return }   // SDK uploads in the same process pass through untouched
            verdicts.value.append(verdict)
            guard verdicts.value.count == 1 else { return }
            reached.signal()
            _ = resume.wait(timeout: .now() + 30)   // paused between verdict and admission
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request: URLRequest = {
            var request = URLRequest(url: URL(string: "https://reports.example.invalid/api/7/envelope/")!)
            request.httpMethod = "POST"
            request.httpBody = body
            return request
        }()
        let upload = Task.detached { try await session.data(for: request) }
        #expect(await Self.wait(reached))
        #expect(verdicts.value == [.forward])    // no cutoff yet: the stale verdict under test
        CrashReporting.setEnabled(false)         // cutoff now covers the planted metric
        CrashReporting.setEnabled(true)          // gate open again
        resume.signal()
        let (_, response) = try await upload.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)   // synthetic: swallowed
        #expect(verdicts.value == [.forward, .swallow])
        #expect(!RecordingURLProtocol.bodies.contains(body))         // never forwarded
    }

    /// Control for `preCutoffMetricBatchIsSwallowedOnTheWire`: the wire check is what drops
    /// the planted batch.
    @MainActor @Test func withoutAnOptOutThePlantedBatchIsDelivered() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        PrivateSentrySDKOnly.capture(MetricRevocationTests.metricEnvelope(
            timestamp: Date().addingTimeInterval(-60), name: "planted"))
        #expect(await SDKHarness.flush(until: {
            ((try? Self.metricItems()) ?? []).contains { $0["name"] as? String == "planted" }
        }))
    }

    @MainActor @Test func reEnableFailsClosedWhenAMetricEnvelopeCannotBeDeleted() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.start(enabled: true, configuration: config)
        // An older queued event: the transport sends the oldest envelope first
        // (`SentryHttpTransport.m:323`) and stops draining when the closed gate refuses it, so the
        // opt-out's and re-enable's flushes never reach the metric envelope. Without it, the
        // opt-out flush would carry the metric batch to the wire check, which swallows it
        // (synthetic 200, the transport deletes it) before the sweep could fail on it.
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        #expect(await SDKHarness.flush(until: {
            !Self.envelopeFiles(in: config.cacheDirectory, containing: "event").isEmpty
        }))
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.metricQueue.sync {}
        #expect(await SDKHarness.flush(until: {
            !Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
        }))
        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        CrashReporting.setEnabled(false)
        RecordingURLProtocol.mode = .accept
        CrashReporting.setEnabled(true)
        #expect(!ConsentGate.shared.isEnabled)
        #expect(CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        await SDKHarness.flush()
        #expect(RecordingURLProtocol.bodies.isEmpty)

        // Next launch: the pending purge empties the cache before the SDK starts.
        let relaunch = SDKHarness.reset(keeping: CrashReporting.preferenceDefaults, copyingCacheFrom: config.cacheDirectory)
        CrashReporting.start(enabled: true, configuration: relaunch)
        #expect(SentrySDK.isEnabled)
        #expect(Self.envelopeFiles(in: relaunch.cacheDirectory, containing: "trace_metric").isEmpty)
        await SDKHarness.flush()
        #expect(!SDKHarness.delivered("trace_metric"))
    }

    @MainActor @Test func nextLaunchDeletesMetricEnvelopesLeftAfterAnOptOut() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        // Recorded after the re-enable and still queued (offline) when the process ends.
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.metricQueue.sync {}
        #expect(await SDKHarness.flush(until: {
            !Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
        }))
        #expect(CrashReportingPreference.hasPendingMetricSweep(in: CrashReporting.preferenceDefaults))
        let relaunch = SDKHarness.reset(keeping: CrashReporting.preferenceDefaults, copyingCacheFrom: config.cacheDirectory)
        CrashReporting.start(enabled: true, configuration: relaunch)
        #expect(Self.envelopeFiles(in: relaunch.cacheDirectory, containing: "trace_metric").isEmpty)
        #expect(!CrashReportingPreference.hasPendingMetricSweep(in: CrashReporting.preferenceDefaults))
        await SDKHarness.flush()
        #expect(!SDKHarness.delivered("trace_metric"))
    }

    enum SweepFailure: CaseIterable, Sendable { case listing, reading }

    /// Makes the next sweep unable to inspect the cache (spec §4.2 "Sweep").
    static func inject(_ failure: SweepFailure) {
        switch failure {
        case .listing:
            CrashReporting.listDirectory = { url in
                if url.lastPathComponent == "envelopes" { throw CocoaError(.fileReadNoPermission) }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            }
        case .reading:
            CrashReporting.readFile = { _ in throw CocoaError(.fileReadNoPermission) }
        }
    }

    /// Review finding (sweep must fail closed): a launch sweep that can't list the envelopes
    /// or read one keeps `pendingMetricSweep`, sets `pendingPurge` and doesn't start the SDK.
    /// The next start recovers by purging the whole cache, even while the cache is still
    /// unreadable (the purge doesn't need to inspect it).
    @MainActor @Test(arguments: SweepFailure.allCases)
    func launchSweepThatCannotInspectTheCacheFailsClosed(_ failure: SweepFailure) async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])   // queued offline, flag set
        CrashReporting.metricQueue.sync {}
        #expect(await SDKHarness.flush(until: {
            !Self.envelopeFiles(in: config.cacheDirectory, containing: "trace_metric").isEmpty
        }))
        let relaunch = SDKHarness.reset(keeping: CrashReporting.preferenceDefaults, copyingCacheFrom: config.cacheDirectory)
        Self.inject(failure)   // after reset: `resetForTesting` restores the seams
        CrashReporting.start(enabled: true, configuration: relaunch)
        #expect(!SentrySDK.isEnabled)
        #expect(!ConsentGate.shared.isEnabled)
        #expect(CrashReportingPreference.hasPendingMetricSweep(in: CrashReporting.preferenceDefaults))
        #expect(CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        #expect(!Self.envelopeFiles(in: relaunch.cacheDirectory, containing: "trace_metric").isEmpty)

        // Recovery: the next start (here in-process; the next launch is the same code) purges.
        CrashReporting.setEnabled(true)
        #expect(SentrySDK.isEnabled)
        #expect(!CrashReportingPreference.hasPendingMetricSweep(in: CrashReporting.preferenceDefaults))
        #expect(!CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        #expect(Self.envelopeFiles(in: relaunch.cacheDirectory, containing: "trace_metric").isEmpty)
        await SDKHarness.flush()
        #expect(!SDKHarness.delivered("trace_metric"))
    }

    /// The SDK's own file manager on a fresh cache, so paths and serialization are the SDK's
    /// (spec §2.5.3).
    private static func sdkFiles() throws -> (cache: URL, files: SentryFileManager) {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricSweep-\(UUID().uuidString)", isDirectory: true)
        let options = Options()
        options.dsn = SDKHarness.dsn
        options.cacheDirectoryPath = cache.path
        let container = SentryDependencyContainer.sharedInstance()
        let files = try SentryFileManager(
            options: options, dateProvider: container.dateProvider, dispatchQueueWrapper: container.dispatchQueueWrapper)
        return (cache, files)
    }

    /// Unit-level, but here because it shares `CrashReporting.removeItem` with the tests above.
    @MainActor @Test func sweepDeletesMetricAndUndeserializableEnvelopesOnly() throws {
        CrashReporting.resetFileSeamsForTesting()   // an earlier serial test may have left a seam injected
        let (cache, files) = try Self.sdkFiles()
        defer { try? FileManager.default.removeItem(at: cache) }
        defer { CrashReporting.resetFileSeamsForTesting() }
        let metric = try #require(files.store(MetricRevocationTests.metricEnvelope(timestamp: Date())))
        let event = try #require(files.store(MetricRevocationTests.eventEnvelope()))
        let junk = URL(fileURLWithPath: event).deletingLastPathComponent().appendingPathComponent("junk.json")
        try Data("not an envelope".utf8).write(to: junk)
        #expect(CrashReporting.deleteMetricEnvelopes(in: cache))
        #expect(!FileManager.default.fileExists(atPath: metric))
        #expect(FileManager.default.fileExists(atPath: event))
        // The transport would delete it unsent (`SentryHttpTransport.m:333-337`): removing it
        // loses nothing, and the sweep never has to guess what it held.
        #expect(!FileManager.default.fileExists(atPath: junk.path))

        let second = try #require(files.store(MetricRevocationTests.metricEnvelope(timestamp: Date())))
        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(!CrashReporting.deleteMetricEnvelopes(in: cache))
        #expect(FileManager.default.fileExists(atPath: second))
    }

    /// Review finding (sweep must fail closed): absent is success, uninspectable is failure.
    @MainActor @Test func sweepFailsClosedWhenTheCacheCannotBeInspected() throws {
        CrashReporting.resetFileSeamsForTesting()   // an earlier serial test may have left a seam injected
        let (cache, files) = try Self.sdkFiles()
        defer { try? FileManager.default.removeItem(at: cache) }
        defer { CrashReporting.resetFileSeamsForTesting() }
        // Absent cache, or a cache without `io.sentry`: nothing to delete.
        #expect(CrashReporting.deleteMetricEnvelopes(in: cache.appendingPathComponent("missing", isDirectory: true)))
        let metric = try #require(files.store(MetricRevocationTests.metricEnvelope(timestamp: Date())))

        for failure in SweepFailure.allCases {
            Self.inject(failure)
            #expect(!CrashReporting.deleteMetricEnvelopes(in: cache), "\(failure)")
            #expect(FileManager.default.fileExists(atPath: metric), "\(failure)")
            CrashReporting.resetFileSeamsForTesting()
        }
        // A file deleted between listing and reading is gone, not a failure.
        CrashReporting.readFile = { _ in throw CocoaError(.fileReadNoSuchFile) }
        #expect(CrashReporting.deleteMetricEnvelopes(in: cache))
        CrashReporting.resetFileSeamsForTesting()
        // Inspectable again: the sweep completes.
        #expect(CrashReporting.deleteMetricEnvelopes(in: cache))
        #expect(!FileManager.default.fileExists(atPath: metric))
    }

    /// Review finding (tallies across consent changes), end to end.
    @MainActor @Test func tallyTotalsFromBeforeAnOptOutAreNeverSent() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let tally = CrashReporting.Tally(.testCount, attributes: ["level": "critical"])
        tally.add(3)
        CrashReporting.setEnabled(false)
        tally.add(5)                         // while off: rejected
        CrashReporting.setEnabled(true)
        tally.flush()                        // the 3 belong to the earlier epoch: discarded
        tally.add(2)
        tally.flush()                        // after the re-enable: sent
        #expect(await Self.waitForMetrics(1))
        await SDKHarness.flush()
        let delivered = try Self.metricItems()
        #expect(delivered.compactMap { $0["value"] as? Int } == [2])
        #expect(delivered.compactMap { Self.metricStrings($0)["level"] } == ["critical"])
    }

    /// A flush that took its total before the opt-out and reaches admission only after the
    /// re-enable: the emission carries the old epoch and is refused. The emit seam holds the
    /// total, so the pause is deterministic.
    @MainActor @Test func tallyEmissionCarriesItsEpochPastAnOptOut() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let held = Locked<[UInt64: UInt]>([:])
        let tally = CrashReporting.Tally(
            .testCount, attributes: ["level": "critical"], interval: 60,
            now: { ProcessInfo.processInfo.systemUptime },
            consent: { CrashReporting.metricEpoch() },
            emit: { value, epoch in held.value[epoch] = value })
        tally.add(4)
        tally.flush()                        // total taken under the current epoch …
        let (epoch, value) = try #require(held.value.first)
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        // … and emitted only now, through the production emission path.
        CrashReporting.count(.testCount, value, attributes: ["level": "critical"], epoch: epoch)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        #expect(await Self.waitForMetrics(1))
        await SDKHarness.flush()
        #expect(try Self.deliveredLevels() == ["warning"])
    }
}
