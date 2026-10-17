import Foundation
import Sentry
import Testing
@testable import ReportsKit

extension CrashReporting.Metric {
    static let testDuration = Self(
        "test.duration", kind: .distribution, unit: .millisecond,
        attributes: ["format": ["cube", "3dl"], "outcome": Self.outcomes])
    static let testCount = Self("test.count", kind: .counter, attributes: ["level": ["warning", "critical"]])
}

extension SerialSuite {
    private static var metricNeedles: [String] {
        var needles = ["jane", "Jane", "Client Smith", "/Users/", "/private/", "CrashReportingTests-",
                       "stable-installation-id"]
        #if os(macOS)
        if let name = Host.current().localizedName, name.count >= 8 { needles.append(name) }
        #endif
        return needles
    }

    /// Every metric delivered so far (shared with `SerialSuite+MetricRevocation`).
    static func metricItems() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "trace_metric" }
            .flatMap { ($0.json?["items"] as? [[String: Any]]) ?? [] }
    }

    static func metricStrings(_ metric: [String: Any]) -> [String: String] {
        let attributes = metric["attributes"] as? [String: [String: Any]] ?? [:]
        return attributes.compactMapValues { $0["value"] as? String }
    }

    private static func metricKeys(_ metric: [String: Any]) -> Set<String> {
        Set((metric["attributes"] as? [String: Any] ?? [:]).keys)
    }

    /// Drains ReportsKit's queue, then flushes until `count` metric items arrived.
    @MainActor static func waitForMetrics(_ count: Int) async -> Bool {
        CrashReporting.metricQueue.sync {}
        return await SDKHarness.flush(until: { ((try? metricItems().count) ?? 0) >= count })
    }

    /// Diagnostic launch whose installation ID is the planted, cached value (same technique as
    /// `SerialSuite+Forwarding.startDiagnostic`).
    @MainActor private static func startMetricsDiagnostic() throws -> CrashReportingConfiguration {
        let config = SDKHarness.reset()
        try FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        try Data("stable-installation-id".utf8)
            .write(to: config.cacheDirectory.appendingPathComponent(CrashReporting.installationFileName))
        CrashReportingPreference.setLastProfile(.diagnostic, in: CrashReporting.preferenceDefaults)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        SentrySDK.startSession()   // caches the installation ID, so the SDK would add user.id
        return config
    }

    @MainActor @Test func strictMetricSendsOnlyAllowlistedAttributes() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        #expect(CrashReporting.activeProfile == .strict)
        SentrySDK.startSession()   // caches this launch's installation ID
        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: "jane"))
            scope.setAttribute(value: "/Users/jane/x", key: "file.path")
        }
        CrashReporting.distribution(.testDuration, 12.5,
                                    attributes: ["format": "cube", "outcome": "success", "path": "/Users/jane/x.cube"])
        CrashReporting.distribution(.testDuration, 30,
                                    attributes: ["format": "/Users/jane/Client Smith.cube", "outcome": "failure"])
        #expect(await Self.waitForMetrics(2))

        let metrics = try Self.metricItems()
        #expect(metrics.count == 2)
        let allowed = CrashReportSanitizer.allowedMetricSDKAttributeKeys.union(["format", "outcome"])
        for metric in metrics {
            #expect(metric["name"] as? String == "test.duration")
            #expect(metric["type"] as? String == "distribution")
            #expect(metric["unit"] as? String == "millisecond")
            #expect(metric["span_id"] == nil)
            let keys = Self.metricKeys(metric)
            #expect(keys.isSubset(of: allowed))
            #expect(!keys.contains { $0.hasPrefix("user.") })
            #expect(Self.metricStrings(metric)["sentry.release"] == "com.example.Test@1.0+1")
            #expect(Self.metricStrings(metric)["sentry.environment"] == "test")
        }
        #expect(Set(metrics.compactMap { Self.metricStrings($0)["format"] }) == ["cube", "other"])
        #expect(Set(metrics.compactMap { $0["trace_id"] as? String }).count == 2)
        for envelope in try SDKHarness.envelopes().filter({ $0.items.contains { $0.type == "trace_metric" } }) {
            // One item per metric envelope (spec §2.5.4): the opt-out sweep may delete whole
            // metric envelopes without losing anything else. Fails if an SDK bump starts mixing.
            #expect(envelope.items.count == 1)
            for needle in Self.metricNeedles {
                #expect(!envelope.text.contains(needle), "leaked \(needle)")
            }
        }
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func diagnosticMetricsKeepTheTraceButNeverTheInstallationID() async throws {
        _ = try Self.startMetricsDiagnostic()
        #expect(CrashReporting.activeProfile == .diagnostic)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.count(.testCount, 3, attributes: ["level": "critical"])
        // Control: a log in the same launch does carry the installation ID.
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await Self.waitForMetrics(2))
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))

        let metrics = try Self.metricItems()
        #expect(Set(metrics.compactMap { $0["trace_id"] as? String }).count == 1)
        #expect(metrics.compactMap { $0["value"] as? Int }.sorted() == [1, 3])
        for metric in metrics {
            #expect(metric["type"] as? String == "counter")
            #expect(metric["unit"] == nil)
            #expect(!Self.metricKeys(metric).contains { $0.hasPrefix("user.") })
        }
        let logs = try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "log" }
            .flatMap { ($0.json?["items"] as? [[String: Any]]) ?? [] }
        #expect(logs.contains { Self.metricStrings($0)["user.id"] == "stable-installation-id" })
        let metricEnvelopes = try SDKHarness.envelopes().filter { $0.items.contains { $0.type == "trace_metric" } }
        #expect(!metricEnvelopes.contains { $0.text.contains("stable-installation-id") })
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func metricsBypassingReportsKitAreDropped() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        SentrySDK.metrics.count(key: "forged", value: 1, attributes: ["path": "/Users/jane"])
        SentrySDK.metrics.distribution(key: "test.duration", value: 1, unit: .millisecond, attributes: [:])
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        #expect(await Self.waitForMetrics(1))
        await SDKHarness.flush()
        #expect(try Self.metricItems().compactMap { $0["name"] as? String } == ["test.count"])
    }

    @MainActor @Test func metricsRecordedWhileOptedOutAreNeverSent() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        CrashReporting.count(.testCount, attributes: ["level": "critical"])
        CrashReporting.setEnabled(true)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        #expect(await Self.waitForMetrics(1))
        await SDKHarness.flush()
        #expect(try Self.metricItems().compactMap { Self.metricStrings($0)["level"] } == ["warning"])
    }

    @MainActor @Test func metricAdmittedBeforeOptOutIsDroppedOnTheQueue() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        // Hold the queue with a blocked work item (never `suspend()`: the opt-out syncs on it
        // from Task A5 on). Released from another thread while `setEnabled(false)` runs or
        // right after it.
        let release = DispatchSemaphore(value: 0)
        CrashReporting.metricQueue.async { release.wait() }
        CrashReporting.count(.testCount, attributes: ["level": "critical"])   // admitted, waiting
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        CrashReporting.setEnabled(false)
        CrashReporting.metricQueue.sync {}   // the held emission ran with the gate closed
        CrashReporting.setEnabled(true)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        #expect(await Self.waitForMetrics(1))
        await SDKHarness.flush()
        #expect(try Self.metricItems().compactMap { Self.metricStrings($0)["level"] } == ["warning"])
    }

    @MainActor @Test func budgetOverflowIsReportedAsADroppedCount() async throws {
        let clock = Locked<TimeInterval>(1_000)
        let config = SDKHarness.reset()
        CrashReporting.metricBudget = MetricBudget(perMinute: 2, perProcess: 100, now: { clock.value })
        CrashReporting.start(enabled: true, configuration: config)
        for _ in 0..<3 { CrashReporting.count(.testCount, attributes: ["level": "warning"]) }
        clock.value += 60
        CrashReporting.count(.testCount, attributes: ["level": "critical"])
        #expect(await Self.waitForMetrics(4))
        let metrics = try Self.metricItems()
        #expect(metrics.filter { $0["name"] as? String == "test.count" }.count == 3)
        let dropped = try #require(metrics.first { $0["name"] as? String == "reportskit.metrics.dropped" })
        #expect(dropped["value"] as? Int == 1)
    }

    /// A synchronous context, so only the synchronous `measure` overload is viable (in an async
    /// context Swift prefers the async one).
    private static func measureSynchronously() -> Int {
        CrashReporting.measure(.testDuration, attributes: ["format": "3dl"]) { 42 }
    }

    @MainActor @Test func measureRecordsOutcomeFromAnyThread() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        let value = await Task.detached { Self.measureSynchronously() }.value
        #expect(value == 42)
        await #expect(throws: CancellationError.self) {
            try await CrashReporting.measure(.testDuration, attributes: ["format": "cube"]) {
                try await Task.sleep(for: .milliseconds(1))
                throw CancellationError()
            }
        }
        #expect(await Self.waitForMetrics(2))
        let outcomes = try Self.metricItems().reduce(into: [String: String]()) {
            $0[Self.metricStrings($1)["format"] ?? "?"] = Self.metricStrings($1)["outcome"]
        }
        #expect(outcomes == ["3dl": "success", "cube": "cancelled"])
    }

    @MainActor @Test func nothingIsRecordedWithMetricsDisabled() async throws {
        var config = SDKHarness.reset()
        config.metricsEnabled = false
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.count(.testCount, attributes: ["level": "warning"])
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        CrashReporting.metricQueue.sync {}
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        #expect(try Self.metricItems().isEmpty)
    }
}
