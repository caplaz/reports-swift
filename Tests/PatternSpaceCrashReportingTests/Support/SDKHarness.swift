import Foundation
import Sentry
@testable import PatternSpaceCrashReporting

enum SDKHarness {
    static let dsn = "https://0123456789abcdef0123456789abcdef@reports.example.test/7"

    /// Suite name + cache dir from the previous `reset()` call, cleaned up at the start of
    /// the next one. A static `atexit` hook (registered once, below) cleans up the very last
    /// one too, so a `swift test` run leaves nothing behind in `~/Library/Preferences` or
    /// `$TMPDIR` regardless of how many tests called `reset()`.
    nonisolated(unsafe) private static var lastSuiteName: String?
    nonisolated(unsafe) private static var lastCacheDirectory: URL?

    private static func cleanUpLeftovers() {
        if let name = lastSuiteName {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            // `removePersistentDomain` only empties the domain in cfprefsd's cache; it
            // doesn't delete the backing plist (verified empirically: the file survives,
            // ~49 bytes of empty bplist). Each suite name is a one-shot UUID never reopened,
            // so it's safe to also unlink the file directly.
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(atPath: path)
        }
        if let directory = lastCacheDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static let registerExitCleanup: Void = {
        atexit { SDKHarness.cleanUpLeftovers() }
    }()

    /// Fresh cache dir + preference suite; SDK closed; network stubbed behind the consent gate.
    /// Callers are `@MainActor` so `CrashReporting.start` installs the hub synchronously.
    @MainActor
    static func reset(mode: RecordingURLProtocol.Mode = .accept) -> CrashReportingConfiguration {
        _ = registerExitCleanup
        cleanUpLeftovers()
        CrashReporting.resetForTesting()
        RecordingURLProtocol.reset(mode: mode)
        RecordingURLProtocol.installBehindConsentProtocol()
        let suite = "SDKHarness.\(UUID().uuidString)"
        lastSuiteName = suite
        CrashReporting.preferenceDefaults = UserDefaults(suiteName: suite)!
        CrashReporting.environmentResolver = nil
        CrashReporting.testOptionsOverride = { options in
            options.enableCrashHandler = false   // don't install signal handlers in the test runner
            options.enableAppHangTracking = false
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportingTests-\(UUID().uuidString)", isDirectory: true)
        lastCacheDirectory = cache
        return CrashReportingConfiguration(
            dsn: dsn, releaseName: "com.caplaz.Test@1.0+1", environment: "test",
            cacheDirectory: cache, tracesSampleRate: 1.0)
    }

    /// `flush` blocks; run it off the main actor so SDK main-queue work can proceed.
    static func flush() async {
        await Task.detached { SentrySDK.flush(timeout: 3) }.value
    }

    /// Flushes until `condition` holds (or `seconds` pass) and returns whether it did.
    ///
    /// A single `SentrySDK.flush` is not a delivery barrier in sentry-cocoa 9.24.0. Every
    /// `start` builds a new `SentryReachability` whose fresh `NWPathMonitor` reports the
    /// initial path as a change (`.none` to `.wiFi`), so `SentryHttpTransport` runs a
    /// `sendAllCachedEnvelopes` on the reachability queue shortly after start. If that drain
    /// is already past `getOldestEnvelope` when the test captures and flushes, the store-then-
    /// send and the flush's own send both bail with "Already sending", and the reachability
    /// drain's "No envelopes left" calls `stopFlushing`. `flush` then returns success
    /// immediately, with the new envelope still on disk and no drain left to pick it up
    /// (a lost wakeup in the transport). Each `flush` dispatches a new drain onto the
    /// transport queue, so flushing again delivers the stranded envelope. Conditions are
    /// observable outcomes: bodies the recorder received, or envelope files in the cache.
    @MainActor @discardableResult
    static func flush(until condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            await flush()
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Whether the recorder has received an envelope item of `type` ("event", "transaction").
    static func delivered(_ type: String) -> Bool {
        ((try? envelopes()) ?? []).flatMap(\.items).contains { $0.type == type }
    }

    static func envelopes() throws -> [Envelope] {
        try RecordingURLProtocol.bodies.map(Envelope.init)
    }

    static func storedEnvelopeCount(in directory: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            if url.deletingLastPathComponent().lastPathComponent == "envelopes" { count += 1 }
        }
        return count
    }
}
