import Foundation
import Sentry
import Testing
@testable import ReportsKit

extension SerialSuite {
    private static func forwardingLogItems() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "log" }
            .flatMap { ($0.json?["items"] as? [[String: Any]]) ?? [] }
    }

    private static func forwardingAttributes(_ log: [String: Any]) -> [String: String] {
        let attributes = log["attributes"] as? [String: [String: Any]] ?? [:]
        return attributes.compactMapValues { $0["value"] as? String }
    }

    @MainActor private static func startDiagnostic() throws -> CrashReportingConfiguration {
        let config = SDKHarness.reset()
        try FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        try Data("stable-installation-id".utf8)
            .write(to: config.cacheDirectory.appendingPathComponent(CrashReporting.installationFileName))
        // `prepareCache` rotates INSTALLATION on a strict → diagnostic transition (so opting in
        // never links the last strict launch's per-launch id to the new diagnostic one); a
        // fresh preference suite's `lastProfile` defaults to `.strict`, which would delete the
        // planted id before the SDK ever reads it. Seed `lastProfile` as `.diagnostic` so this
        // looks like the second diagnostic launch and the planted id survives (same technique as
        // `SerialSuite+Profiles.diagnosticSessionsAndEventsCarryTheInstallationID`).
        CrashReportingPreference.setLastProfile(.diagnostic, in: CrashReporting.preferenceDefaults)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        // Reads (and caches in memory) the installation ID synchronously; the SDK's own
        // background caching may not have run yet, and logs only see the cached value.
        SentrySDK.startSession()
        return config
    }

    @MainActor @Test func forwardedLogsCarryCategoryLevelAndInstallationIDInDiagnostic() async throws {
        _ = try Self.startDiagnostic()
        CrashReporting.forwardLog(.error, category: "SDI", message: "session start failed: /Users/jane/Client Smith.cube")
        CrashReporting.forwardLog(.info, category: "LUT", message: "loaded 33-point cube")
        #expect(await SDKHarness.flush(until: { ((try? Self.forwardingLogItems().count) ?? 0) >= 2 }))
        let logs = try Self.forwardingLogItems()
        let error = try #require(logs.first { $0["body"] as? String == "session start failed: /Users/jane/Client Smith.cube" })
        #expect(error["level"] as? String == "error")
        let attributes = Self.forwardingAttributes(error)
        #expect(attributes["report.source"] == "app-log")
        #expect(attributes["report.category"] == "SDI")
        #expect(attributes["user.id"] == "stable-installation-id")
        #expect(attributes["report.dropped"] == nil)
        let keys = Set(attributes.keys)
        #expect(keys.isSubset(of: CrashReportSanitizer.allowedLogAttributeKeys(.diagnostic)))
        let info = try #require(logs.first { $0["body"] as? String == "loaded 33-point cube" })
        #expect(info["level"] as? String == "info")
        #expect(Self.forwardingAttributes(info)["report.category"] == "LUT")
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func forwardLogIsANoOpInStrict() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.forwardLog(.error, category: "SDI", message: "must not leave")
        CrashReporting.log(.error, "sentinel", operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        await SDKHarness.flush()
        #expect(try Self.forwardingLogItems().compactMap { $0["body"] as? String } == ["sentinel"])
    }

    @MainActor @Test func forwardedLogsStopAtOptOut() async throws {
        _ = try Self.startDiagnostic()
        CrashReporting.setEnabled(false)
        CrashReporting.forwardLog(.error, category: "SDI", message: "while off")
        CrashReporting.setEnabled(true)
        CrashReporting.forwardLog(.error, category: "LUT", message: "sentinel")
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("log") }))
        await SDKHarness.flush()
        #expect(try Self.forwardingLogItems().compactMap { $0["body"] as? String } == ["sentinel"])
        SentrySDK.endSession()
        await SDKHarness.flush()
    }

    @MainActor @Test func repeatedForwardedLogsAreBudgetedAndCounted() async throws {
        _ = try Self.startDiagnostic()
        for _ in 0..<5 { CrashReporting.forwardLog(.error, category: "SDI.Frames", message: "DeckLink dropped the frame") }
        CrashReporting.forwardLog(.error, category: "SDI", message: "sentinel")
        #expect(await SDKHarness.flush(until: { ((try? Self.forwardingLogItems().count) ?? 0) >= 2 }))
        let logs = try Self.forwardingLogItems()
        #expect(logs.compactMap { $0["body"] as? String }.sorted() == ["DeckLink dropped the frame", "sentinel"])
        let sentinel = try #require(logs.first { $0["body"] as? String == "sentinel" })
        #expect(Self.forwardingAttributes(sentinel)["report.dropped"] == "4")
        SentrySDK.endSession()
        await SDKHarness.flush()
    }
}
