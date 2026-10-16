import Foundation
import Sentry
import Testing
@testable import ReportsKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension SerialSuite {
    private static let plantedInstallationID = "stable-installation-id"

    private static func plantInstallationID(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(plantedInstallationID.utf8)
            .write(to: directory.appendingPathComponent(CrashReporting.installationFileName))
    }

    private static func sessionDistinctIDs() throws -> [String] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }
            .compactMap { $0.json?["did"] as? String }
    }

    private static func events() throws -> [[String: Any]] {
        try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "event" }.compactMap(\.json)
    }

    private static func exceptionValue(_ event: [String: Any]) -> String? {
        (((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)?["value"] as? String
    }

    // MARK: Profile selection

    @MainActor @Test func profileIsDiagnosticOnlyWhenBothSettingsAreOn() async {
        var config = SDKHarness.reset()
        #expect(CrashReporting.activeProfile == .strict)          // SDK not started
        CrashReporting.start(enabled: true, configuration: config)
        #expect(CrashReporting.activeProfile == .strict)          // detailed diagnostics off (default)

        config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: false, configuration: config)
        #expect(CrashReporting.activeProfile == .strict)          // reporting off: SDK not started
        CrashReporting.setEnabled(true)                           // starts the SDK, both settings on
        #expect(CrashReporting.activeProfile == .diagnostic)
        #expect(CrashReportingPreference.lastProfile(in: CrashReporting.preferenceDefaults) == .diagnostic)
    }

    @MainActor @Test func strictSessionsUseAPerLaunchDistinctID() async throws {
        let config = SDKHarness.reset()
        ConsentSessionTracker.shared.isAppActive = { true }
        try Self.plantInstallationID(in: config.cacheDirectory)
        CrashReporting.start(enabled: true, configuration: config)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") }))
        let dids = try Self.sessionDistinctIDs()
        #expect(!dids.isEmpty)
        for did in dids {
            #expect(did != Self.plantedInstallationID)
            #expect(UUID(uuidString: did) != nil)
        }
    }

    @MainActor @Test func diagnosticSessionsAndEventsCarryTheInstallationID() async throws {
        let config = SDKHarness.reset()
        ConsentSessionTracker.shared.isAppActive = { true }
        try Self.plantInstallationID(in: config.cacheDirectory)
        // The ID is stable from the second diagnostic launch on (the first one after a strict
        // launch rotates it: `firstDiagnosticLaunchGetsANewStableID`).
        CrashReportingPreference.setLastProfile(.diagnostic, in: CrashReporting.preferenceDefaults)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 4), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") && SDKHarness.delivered("event") }))
        #expect(try Self.sessionDistinctIDs().contains(Self.plantedInstallationID))
        let event = try #require(try Self.events().first)
        let user = try #require(event["user"] as? [String: Any])
        #expect(user["id"] as? String == Self.plantedInstallationID)
        #expect(Set(user.keys) == ["id"])
        #expect((event["tags"] as? [String: String])?["report.profile"] == "diagnostic")
    }

    // MARK: Handled errors

    @MainActor @Test func diagnosticHandledErrorCarriesErrorTextWithStableGrouping() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSFilePathErrorKey: "/Users/jane/Documents/Client Smith.cube",
            NSLocalizedDescriptionKey: "Jane's file couldn't be saved"
        ])
        CrashReporting.capture(error, operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let event = try #require(try Self.events().first)
        let value = try #require(Self.exceptionValue(event))
        #expect(value.contains("/Users/jane/Documents/Client Smith.cube"))
        #expect(value.contains("Jane's file couldn't be saved"))
        #expect((event["tags"] as? [String: String])?["report.error"] == "NSError code=4")
        #expect(event["fingerprint"] as? [String] == ["report", "exportSave", "NSError code=4"])
        #expect(event["server_name"] == nil)
        #if os(macOS)
        if let name = Host.current().localizedName, name.count >= 8 {
            for envelope in try SDKHarness.envelopes() { #expect(!envelope.text.contains(name)) }
        }
        #endif
    }

    @MainActor @Test func strictHandledErrorIsRedactedAndTaggedStrict() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 4,
                                       userInfo: [NSFilePathErrorKey: "/Users/jane/x"]), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let event = try #require(try Self.events().first)
        #expect(Self.exceptionValue(event) == "<redacted>")
        #expect((event["tags"] as? [String: String])?["report.profile"] == "strict")
    }

    // MARK: Collection-time provenance

    /// Replays an event the way sentry-cocoa 9.24.0 replays stored data from an earlier launch:
    /// without the current scope. Crash reports, fatal hangs and watchdog terminations are
    /// captured as fatal and skip scope application (`SentryClient.m:778-784`); stored app hangs
    /// are captured with an empty `Scope()` (`SentryHangTrackingIntegration.swift:161,181`).
    /// `collectedUnder` is the `report.profile` tag the collecting launch's scope gave it
    /// (`nil`: collected before the tag existed, e.g. by ReportsKit 0.2.x).
    private static func replay(_ event: Event, collectedUnder profile: CrashReporting.PrivacyProfile?) {
        if let profile { event.tags = ["report.profile": profile.rawValue] }
        SentrySDK.capture(event: event, scope: Scope())
    }

    private static func detailedEvent(level: SentryLevel, type: String = "NSInvalidArgumentException") -> Event {
        let event = Event(level: level)
        event.exceptions = [Exception(value: "/Users/jane/Client Smith.cube", type: type)]
        return event
    }

    private static func sentProfileTag(_ event: [String: Any]) -> String? {
        (event["tags"] as? [String: String])?["report.profile"]
    }

    @MainActor @Test func strictTaggedCrashStaysStrictAfterOptingIn() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        #expect(CrashReporting.activeProfile == .diagnostic)
        Self.replay(Self.detailedEvent(level: .fatal), collectedUnder: .strict)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "<redacted>")
        #expect(Self.sentProfileTag(sent) == "strict")
    }

    // Regression (review): provenance must not depend on the wall clock. A strict-launch crash
    // stamped in the future (clock rolled back since) stays strict after opting in.
    @MainActor @Test func strictTaggedEventWithAFutureTimestampStaysStrictAfterOptingIn() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        let crash = Self.detailedEvent(level: .fatal, type: "EXC_BAD_ACCESS")
        crash.timestamp = Date(timeIntervalSinceNow: 86_400)
        Self.replay(crash, collectedUnder: .strict)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "<redacted>")
        #expect(Self.sentProfileTag(sent) == "strict")
    }

    @MainActor @Test func untaggedReplayedEventIsStrict() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        Self.replay(Self.detailedEvent(level: .fatal), collectedUnder: nil)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "<redacted>")
        #expect(Self.sentProfileTag(sent) == "strict")
    }

    @MainActor @Test func diagnosticTaggedPreviousLaunchEventKeepsDetailWhenStartedDiagnostic() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        Self.replay(Self.detailedEvent(level: .fatal), collectedUnder: .diagnostic)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "/Users/jane/Client Smith.cube")
        #expect(Self.sentProfileTag(sent) == "diagnostic")
    }

    // Regression (review): sentry-cocoa replays an app hang stored by the previous launch at
    // `.error` level after `crashedLastLaunch`; severity must not decide its profile.
    @MainActor @Test func replayedErrorLevelHangFromAStrictLaunchStaysStrictAfterOptingIn() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        let hang = Self.detailedEvent(level: .error, type: "App Hanging")
        let image = DebugMeta()
        image.codeFile = "/Users/jane/Applications/MyApp.app/Contents/MacOS/MyApp"
        hang.debugMeta = [image]
        hang.breadcrumbs = [{ let b = Breadcrumb(level: .info, category: "ui"); b.message = "/Users/jane/x"; return b }()]
        Self.replay(hang, collectedUnder: .strict)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "<redacted>")
        let text = try SDKHarness.envelopes().map(\.text).joined()
        #expect(!text.contains("/Users/jane"))
    }

    // Verifies SentryScope.m:635-642 end to end: when the current (diagnostic) scope is applied
    // to an event that already carries a collection tag, the event's own tag wins.
    @MainActor @Test func currentScopeDoesNotOverrideTheEventsCollectionTag() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        let event = Self.detailedEvent(level: .error)
        event.tags = ["report.profile": "strict"]
        SentrySDK.capture(event: event)                              // current scope applied
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let sent = try #require(try Self.events().first)
        #expect(Self.exceptionValue(sent) == "<redacted>")
        #expect(Self.sentProfileTag(sent) == "strict")
    }

    @Test func eventProfileComesFromTheCollectionTagOnly() {
        // Unit check of the rule itself: the more private of the started profile and the event's
        // own `report.profile` tag; missing or unknown tag = strict. Level and timestamp are
        // irrelevant.
        func event(_ tag: String?, level: SentryLevel = .fatal, timestamp: Date? = Date()) -> Event {
            let event = Event(level: level)
            event.timestamp = timestamp
            event.tags = tag.map { ["report.profile": $0] }
            return event
        }
        #expect(CrashReporting.eventProfile(for: event("diagnostic"), started: .diagnostic) == .diagnostic)
        #expect(CrashReporting.eventProfile(for: event("diagnostic"), started: .strict) == .strict)
        #expect(CrashReporting.eventProfile(for: event("strict"), started: .diagnostic) == .strict)
        #expect(CrashReporting.eventProfile(for: event(nil), started: .diagnostic) == .strict)
        #expect(CrashReporting.eventProfile(for: event("verbose"), started: .diagnostic) == .strict)
        #expect(CrashReporting.eventProfile(
            for: event("strict", level: .info, timestamp: .distantFuture), started: .diagnostic) == .strict)
        #expect(CrashReporting.eventProfile(
            for: event("diagnostic", level: .info, timestamp: nil), started: .diagnostic) == .diagnostic)
    }

    // MARK: Cache preparation and purges

    @MainActor @Test func downgradeDiscardsEnvelopesQueuedInDiagnostic() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1 }))
        SentrySDK.close()                                 // simulate process exit (offline: kept on disk)
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        RecordingURLProtocol.mode = .accept
        CrashReporting.start(enabled: true, configuration: config)   // next launch, strict
        #expect(CrashReporting.activeProfile == .strict)
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) == 0)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 2), operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let profiles = try Self.events().map { ($0["tags"] as? [String: String])?["report.profile"] }
        #expect(profiles == ["strict"])
    }

    // Regression (review): cache cleanup must fail closed.
    @MainActor @Test func failedDowngradePurgeKeepsSDKOffAndRetries() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1 }))
        SentrySDK.close()                                          // simulate process exit
        CrashReporting.setDetailedDiagnosticsEnabled(false)
        RecordingURLProtocol.mode = .accept
        RecordingURLProtocol.reset()

        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        CrashReporting.start(enabled: true, configuration: config)   // next launch, purge fails
        #expect(!SentrySDK.isEnabled)
        #expect(!ConsentGate.shared.isEnabled)
        #expect(CrashReportingPreference.lastProfile(in: CrashReporting.preferenceDefaults) == .diagnostic)
        #expect(CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(RecordingURLProtocol.bodies.isEmpty)               // nothing uploaded

        CrashReporting.removeItem = { try FileManager.default.removeItem(at: $0) }
        CrashReporting.setEnabled(true)                            // retry: purge succeeds, SDK starts
        #expect(SentrySDK.isEnabled)
        #expect(CrashReportingPreference.lastProfile(in: CrashReporting.preferenceDefaults) == .strict)
        #expect(!CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) == 0)
    }

    // Regression (review): a purge that fails while the user is opted out must not be forgotten.
    // Re-enabling — even with diagnostics selected — starts nothing until the purge succeeds.
    @MainActor @Test func failedOptedOutPurgeBlocksStartUntilItSucceeds() async throws {
        let config = SDKHarness.reset(mode: .failConnection)
        CrashReporting.start(enabled: true, configuration: config)    // launch 1: queues offline
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 1), operation: .profileSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1 }))
        SentrySDK.close()                                             // simulate process exit
        RecordingURLProtocol.mode = .accept
        RecordingURLProtocol.reset()

        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        CrashReporting.start(enabled: false, configuration: config)   // launch 2, opted out: purge fails
        #expect(CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.setEnabled(true)                               // re-enable, diagnostics selected
        #expect(!SentrySDK.isEnabled)
        #expect(!ConsentGate.shared.isEnabled)
        #expect(CrashReporting.activeProfile == .strict)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(RecordingURLProtocol.bodies.isEmpty)                  // nothing uploaded
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) >= 1)

        CrashReporting.removeItem = { try FileManager.default.removeItem(at: $0) }
        CrashReporting.setEnabled(true)                               // retry: purge, then start
        #expect(SentrySDK.isEnabled)
        #expect(CrashReporting.activeProfile == .diagnostic)
        #expect(!CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        #expect(SDKHarness.storedEnvelopeCount(in: config.cacheDirectory) == 0)
        await SDKHarness.flush()
        #expect(!SDKHarness.delivered("event"))                      // launch 1's report is gone
    }

    @MainActor @Test func successfulOptedOutPurgeClearsThePendingFlag() async throws {
        let config = SDKHarness.reset()
        try Self.plantInstallationID(in: config.cacheDirectory)
        CrashReporting.start(enabled: false, configuration: config)
        #expect(!CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
        #expect(!FileManager.default.fileExists(atPath: config.cacheDirectory.path))
    }

    @MainActor @Test func failedInstallationDeletionKeepsSDKOff() async throws {
        let config = SDKHarness.reset()
        try Self.plantInstallationID(in: config.cacheDirectory)
        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        CrashReporting.start(enabled: true, configuration: config)
        #expect(!SentrySDK.isEnabled)
        #expect(!ConsentGate.shared.isEnabled)
    }

    @MainActor @Test func missingItemsCountAsCleaned() throws {
        _ = SDKHarness.reset()                                        // fresh preference suite
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReportsKitPrep-\(UUID().uuidString)")
        #expect(CrashReporting.prepareCache(dir, profile: .strict, previous: .strict))
        #expect(CrashReporting.prepareCache(dir, profile: .strict, previous: .diagnostic))
        #expect(CrashReporting.prepareCache(dir, profile: .diagnostic, previous: .strict))
        CrashReportingPreference.setPendingPurge(true, in: CrashReporting.preferenceDefaults)
        #expect(CrashReporting.prepareCache(dir, profile: .diagnostic, previous: .diagnostic))
        #expect(!CrashReportingPreference.hasPendingPurge(in: CrashReporting.preferenceDefaults))
    }

    // MARK: Consent-driven sessions

    private static func lifecycleNames() -> (active: Notification.Name, resign: Notification.Name) {
        #if os(macOS)
        (NSApplication.didBecomeActiveNotification, NSApplication.willResignActiveNotification)
        #else
        (UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification)
        #endif
    }

    private static func sessionIDs() throws -> Set<String> {
        Set(try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }
            .compactMap(\.json).compactMap { $0["sid"] as? String })
    }

    // Regression (review): no session is produced while opted out, and nothing from the
    // opted-out period uploads on re-enable.
    @MainActor @Test func noSessionsAreProducedWhileOptedOut() async throws {
        let config = SDKHarness.reset()                    // resets the tracker seams first
        let center = NotificationCenter()
        ConsentSessionTracker.shared.notificationCenter = center
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") }))
        let consentedIDs = try Self.sessionIDs()

        CrashReporting.setEnabled(false)
        let (active, resign) = Self.lifecycleNames()
        for _ in 0..<3 {                                   // background/foreground while off
            center.post(name: resign, object: nil)
            center.post(name: active, object: nil)
        }
        RecordingURLProtocol.reset()
        CrashReporting.setEnabled(true)
        // Wait for a NEW sid: the consented session's final (`exited`) update, queued while the
        // gate was closed, is drained on re-enable too and may arrive first.
        #expect(await SDKHarness.flush(until: {
            (try? Self.sessionIDs().subtracting(consentedIDs).isEmpty == false) ?? false
        }))
        await SDKHarness.flush()
        // Exactly one new session (started at re-enable); none from the opted-out period.
        let newIDs = try Self.sessionIDs().subtracting(consentedIDs)
        #expect(newIDs.count == 1)
    }

    // Regression (review): a revocation racing an in-flight start must not leave a session
    // open (or persisted for upload) while opted out.
    @MainActor @Test func revocationDuringPendingStartLeavesNoSessionOpen() async throws {
        let config = SDKHarness.reset()
        let center = NotificationCenter()
        ConsentSessionTracker.shared.notificationCenter = center
        ConsentSessionTracker.shared.isAppActive = { false }
        CrashReporting.start(enabled: true, configuration: config)      // inactive: no session
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        ConsentSessionTracker.shared.beforeStartEffect = {
            entered.signal()
            release.wait()
        }
        let (active, _) = Self.lifecycleNames()
        let poster = Thread { center.post(name: active, object: nil) }   // start reserved, paused
        poster.start()
        await Task.detached { DispatchQueue.global().sync { _ = entered.wait(timeout: .now() + 5) } }.value
        let revoker = Task.detached { CrashReporting.setEnabled(false) }  // blocks on the tracker lock
        try await Task.sleep(nanoseconds: 100_000_000)
        ConsentSessionTracker.shared.beforeStartEffect = nil
        release.signal()
        await revoker.value
        // While opted out: gate closed and no session open locally.
        #expect(!ConsentGate.shared.isEnabled)
        #expect(!ConsentSessionTracker.shared.isSessionOpen)
        // Re-enable, then the paused-start session's final update (same sid) is `exited`.
        CrashReporting.setEnabled(true)
        #expect(await SDKHarness.flush(until: {
            let items = (try? SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }
                .compactMap(\.json)) ?? []
            let sids = Set(items.compactMap { $0["sid"] as? String })
            return sids.contains { sid in
                items.contains { $0["sid"] as? String == sid && $0["status"] as? String == "exited" }
            }
        }))
    }

    // Regression (review): manual tracking must still close a force-quit launch's session.
    @MainActor @Test func cachedSessionFromAForceQuitIsClosedAsAbnormal() async throws {
        var config = SDKHarness.reset()
        let defaults = CrashReporting.preferenceDefaults
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)     // launch 1: session stored
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") }))
        let firstSid = try #require(try Self.sessionIDs().first)
        // Simulate a force quit: tear down without ending the session (close() would end it).
        ConsentSessionTracker.shared.resetForTesting()
        SentrySDK.close()
        config = SDKHarness.reset(keeping: defaults, copyingCacheFrom: config.cacheDirectory)
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)     // launch 2
        #expect(await SDKHarness.flush(until: {
            (try? SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }.compactMap(\.json)
                .contains { $0["sid"] as? String == firstSid && $0["status"] as? String == "abnormal" }) ?? false
        }))
    }

    @MainActor @Test func sessionFollowsAppActivityWhileConsented() async throws {
        let config = SDKHarness.reset()                    // resets the tracker seams first
        let center = NotificationCenter()
        ConsentSessionTracker.shared.notificationCenter = center
        ConsentSessionTracker.shared.isAppActive = { false }
        CrashReporting.start(enabled: true, configuration: config)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!SDKHarness.delivered("session"))         // inactive app: no session yet
        let (active, resign) = Self.lifecycleNames()
        center.post(name: active, object: nil)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") }))
        center.post(name: resign, object: nil)             // ends it (status exited)
        #expect(await SDKHarness.flush(until: {
            (try? SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }
                .compactMap(\.json).contains { $0["status"] as? String == "exited" }) ?? false
        }))
    }

    // Regression (review): opting in starts a new stable ID, unlinked from the last strict launch.
    /// `did`s of sessions opened by the current launch (`init == true`), excluding updates of
    /// recovered earlier sessions.
    private static func newSessionDistinctIDs() throws -> Set<String> {
        Set(try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "session" }.compactMap(\.json)
            .filter { $0["init"] as? Bool == true }.compactMap { $0["did"] as? String })
    }

    @MainActor @Test func firstDiagnosticLaunchGetsANewStableID() async throws {
        // Each simulated relaunch copies the cache to a NEW path: SentryInstallation caches IDs
        // in a static per-path dictionary that SentrySDK.close() does not clear (review).
        var config = SDKHarness.reset()
        let defaults = CrashReporting.preferenceDefaults
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)            // strict launch
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("session") }))
        let strictDIDs = try Self.newSessionDistinctIDs()

        CrashReporting.setDetailedDiagnosticsEnabled(true)
        config = SDKHarness.reset(keeping: defaults, copyingCacheFrom: config.cacheDirectory)
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)            // 1st diagnostic
        #expect(await SDKHarness.flush(until: { (try? Self.newSessionDistinctIDs().isEmpty == false) ?? false }))
        let firstDiagnostic = try Self.newSessionDistinctIDs()
        #expect(firstDiagnostic.count == 1)
        #expect(firstDiagnostic.isDisjoint(with: strictDIDs))
        let stableID = try #require(firstDiagnostic.first)

        config = SDKHarness.reset(keeping: defaults, copyingCacheFrom: config.cacheDirectory)
        ConsentSessionTracker.shared.isAppActive = { true }
        CrashReporting.start(enabled: true, configuration: config)            // 2nd diagnostic
        #expect(await SDKHarness.flush(until: { (try? Self.newSessionDistinctIDs().isEmpty == false) ?? false }))
        #expect(try Self.newSessionDistinctIDs() == [stableID])              // stable from here on
    }

    @MainActor @Test func failedIDRotationOnOptInKeepsSDKOff() async throws {
        let config = SDKHarness.reset()
        try Self.plantInstallationID(in: config.cacheDirectory)
        CrashReportingPreference.setLastProfile(.strict, in: CrashReporting.preferenceDefaults)
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        CrashReporting.start(enabled: true, configuration: config)
        #expect(!SentrySDK.isEnabled)
        #expect(!ConsentGate.shared.isEnabled)
        #expect(CrashReportingPreference.lastProfile(in: CrashReporting.preferenceDefaults) == .strict)
    }

    // MARK: Consent marker

    @MainActor @Test func eventTaggedOptedOutAtCollectionIsDroppedAfterReEnable() async throws {
        let config = SDKHarness.reset()
        CrashReporting.setDetailedDiagnosticsEnabled(true)
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        let hang = Event(level: .error)                               // detected while off
        hang.exceptions = [Exception(value: "hang", type: "App Hanging")]
        hang.tags = ["report.consent": "off", "report.profile": "diagnostic"]
        CrashReporting.setEnabled(true)
        SentrySDK.capture(event: hang, scope: Scope())                // replayed after re-enable
        let crash = Event(level: .fatal)                              // crash while off, replayed later
        crash.exceptions = [Exception(value: "crash", type: "EXC_BAD_ACCESS")]
        crash.tags = ["report.consent": "off", "report.profile": "diagnostic"]
        SentrySDK.capture(event: crash, scope: Scope())
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 9), operation: .exportSave)   // sentinel
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        await SDKHarness.flush()
        let events = try Self.events()
        #expect(events.count == 1)
        #expect(events.compactMap(Self.exceptionValue).allSatisfy { $0 != "hang" && $0 != "crash" })
        #expect(events.allSatisfy { ($0["tags"] as? [String: String])?["report.consent"] == nil })
    }

    @MainActor @Test func optOutMarksTheScopeAndReEnableClearsIt() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        func scopeTags() -> [String: String] {
            var tags: [String: String] = [:]
            SentrySDK.configureScope { tags = $0.tags }
            return tags
        }
        #expect(scopeTags()["report.consent"] == nil)
        #expect(scopeTags()["report.profile"] == "strict")
        CrashReporting.setEnabled(false)
        #expect(scopeTags()["report.consent"] == "off")
        CrashReporting.setEnabled(true)
        #expect(scopeTags()["report.consent"] == nil)
        // A live event after re-enable is sent, without the marker.
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 3), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let event = try #require(try Self.events().first)
        #expect((event["tags"] as? [String: String])?["report.consent"] == nil)
    }

    // Regression (review): overlapping enable/disable calls end in the last call's state.
    @MainActor @Test func overlappingEnableAndDisableEndDisabled() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        CrashReporting.afterConsentMarkerRemovedForTesting = {
            paused.signal()
            resume.wait()
        }
        let enabling = Thread { CrashReporting.setEnabled(true) }
        enabling.start()
        await Task.detached { DispatchQueue.global().sync { _ = paused.wait(timeout: .now() + 5) } }.value
        let disabling = Task.detached { CrashReporting.setEnabled(false) }   // must wait for enabling
        try await Task.sleep(nanoseconds: 100_000_000)
        CrashReporting.afterConsentMarkerRemovedForTesting = nil
        resume.signal()
        await disabling.value
        #expect(!CrashReportingPreference.isEnabled(in: CrashReporting.preferenceDefaults))
        #expect(!ConsentGate.shared.isEnabled)
        #expect(!ConsentSessionTracker.shared.isSessionOpen)
        var tag: String?
        SentrySDK.configureScope { tag = $0.tags[CrashReportSanitizer.consentTagKey] }
        #expect(tag == CrashReportSanitizer.consentOffValue)
    }

    // MARK: Hang suppression

    @MainActor @Test func hangsAfterAnOptOutAreDroppedForTheRestOfTheProcess() async throws {
        let config = SDKHarness.reset()
        CrashReporting.start(enabled: true, configuration: config)
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        // Stand-in for a detection that applied the scope after re-enable.
        let hang = Event(level: .error)
        let exception = Exception(value: "hang", type: "App Hanging")
        exception.mechanism = Mechanism(type: "AppHang")
        hang.exceptions = [exception]
        SentrySDK.capture(event: hang)                       // current scope carries report.hangs=off
        CrashReporting.capture(NSError(domain: NSCocoaErrorDomain, code: 3), operation: .exportSave)
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("event") }))
        let events = try Self.events()
        #expect(events.count == 1)                           // only the handled error
        for envelope in try SDKHarness.envelopes() { #expect(!envelope.text.contains("report.hangs")) }
    }

    // MARK: Trace consent

    // Regression (review): a transaction started while consented, finished while opted out,
    // and processed after re-enable is not delivered.
    @MainActor @Test func transactionSpanningAnOptOutIsNotDelivered() async throws {
        let config = SDKHarness.reset()
        TraceConsent.shared.random = { 0 }
        CrashReporting.start(enabled: true, configuration: config)
        let transaction = SentrySDK.startTransaction(name: "spanning", operation: "test")
        CrashReporting.setEnabled(false)
        transaction.finish()
        CrashReporting.setEnabled(true)
        let started = SentrySDK.startTransaction(name: "after", operation: "test")    // unbound
        let bound = SentrySDK.startTransaction(name: "bound", operation: "test", bindToScope: true)
        started.finish()                     // finishes while a different transaction is bound
        bound.finish()
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("transaction") }))
        let names = try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "transaction" }
            .compactMap(\.json).compactMap { $0["transaction"] as? String }
        #expect(Set(names) == ["after", "bound"])
    }

    // Regression (review): tracing works right after a normal enabled launch.
    @MainActor @Test func transactionIsDeliveredAfterInitialStart() async throws {
        let config = SDKHarness.reset()
        TraceConsent.shared.random = { 0 }
        CrashReporting.start(enabled: true, configuration: config)
        SentrySDK.startTransaction(name: "initial", operation: "test").finish()
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("transaction") }))
    }

    private static func transactionContext(_ name: String, trace: SentryId) -> TransactionContext {
        TransactionContext(
            name: name, operation: "test", trace: trace, spanId: SpanId(), parentSpanId: nil,
            parentSampled: .undecided, parentSampleRate: nil, parentSampleRand: nil)
    }

    // Regression (review): transactions sharing a trace ID across a revocation are told apart.
    @MainActor @Test func sharedTraceIDDoesNotLetASpanningTransactionThrough() async throws {
        let config = SDKHarness.reset()
        TraceConsent.shared.random = { 0 }
        CrashReporting.start(enabled: true, configuration: config)
        let trace = SentryId()
        let spanning = SentrySDK.startTransaction(transactionContext: Self.transactionContext("spanning", trace: trace))
        CrashReporting.setEnabled(false)
        CrashReporting.setEnabled(true)
        let fresh = SentrySDK.startTransaction(transactionContext: Self.transactionContext("fresh", trace: trace))
        spanning.finish()                                  // finishes first: must not use fresh's admission
        fresh.finish()
        #expect(await SDKHarness.flush(until: { SDKHarness.delivered("transaction") }))
        let names = try SDKHarness.envelopes().flatMap(\.items).filter { $0.type == "transaction" }
            .compactMap(\.json).compactMap { $0["transaction"] as? String }
        #expect(names == ["fresh"])
    }
}
