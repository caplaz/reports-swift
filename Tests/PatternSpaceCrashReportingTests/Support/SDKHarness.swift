import Foundation
import Sentry
@testable import PatternSpaceCrashReporting

enum SDKHarness {
    static let dsn = "https://0123456789abcdef0123456789abcdef@reports.example.test/7"

    /// Fresh cache dir + preference suite; SDK closed; network stubbed behind the consent gate.
    /// Callers are `@MainActor` so `CrashReporting.start` installs the hub synchronously.
    @MainActor
    static func reset(mode: RecordingURLProtocol.Mode = .accept) -> CrashReportingConfiguration {
        CrashReporting.resetForTesting()
        RecordingURLProtocol.reset(mode: mode)
        RecordingURLProtocol.installBehindConsentProtocol()
        let suite = "SDKHarness.\(UUID().uuidString)"
        CrashReporting.preferenceDefaults = UserDefaults(suiteName: suite)!
        CrashReporting.environmentResolver = nil
        CrashReporting.testOptionsOverride = { options in
            options.enableCrashHandler = false   // don't install signal handlers in the test runner
            options.enableAppHangTracking = false
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportingTests-\(UUID().uuidString)", isDirectory: true)
        return CrashReportingConfiguration(
            dsn: dsn, releaseName: "com.caplaz.Test@1.0+1", environment: "test",
            cacheDirectory: cache, tracesSampleRate: 1.0)
    }

    /// `flush` blocks; run it off the main actor so SDK main-queue work can proceed.
    static func flush() async {
        await Task.detached { SentrySDK.flush(timeout: 3) }.value
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
