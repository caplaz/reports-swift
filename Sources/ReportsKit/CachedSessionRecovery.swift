import Foundation
// SPI from the 9.24.0 binary's .private.swiftinterface (exact pin; re-verify on every bump):
// SentryDependencyContainer, SentryFileManager (current session, lastInForeground timestamp),
// SentrySession.endAbnormal/endExited/started,
// SentryEnvelope(header:singleItem:), SentryEnvelopeHeader.empty(), SentryEnvelopeItem(session:).
@_spi(Private) import Sentry

/// Closes the previous launch's unfinished release-health session (backgrounded and killed,
/// force quit, SIGKILL, power loss) — what sentry-cocoa's SessionTracker does via the hub's
/// private `closeCachedSessionWithTimestamp:` (`SentryHub.m:197-229`), which ReportsKit cannot
/// call because auto session tracking is off and the hub isn't public. Exited at the last
/// time the app resigned active when `ConsentSessionTracker` recorded one (the SDK's
/// `lastInForeground` file), else abnormal.
enum CachedSessionRecovery {
    /// Call on the main thread after `SentrySDK.start`, before the first `startSession` of the
    /// process (which stores a new current session over the cached one).
    static func closePreviousLaunchSession() {
        // A crashed launch's session was already moved to "crashed" and deleted by the crash
        // integration during `start` (`SentryCrashIntegration.swift:193`,
        // `SentryCrashIntegrationSessionHandler.swift:47-75`); the hub skips that case too.
        // `lastRunStatus` reads `crashedLastLaunch` synchronously (`SentrySDKInternal.m:503-512`).
        guard SentrySDK.isEnabled, SentrySDK.lastRunStatus != .didCrash, let fileManager = makeFileManager()
        else { return }
        let lastInForeground = fileManager.readTimestampLastInForeground()
        fileManager.deleteTimestampLastInForeground()
        guard let session = fileManager.readCurrentSession() else { return }
        if let lastInForeground {
            session.endExited(withTimestamp: lastInForeground)
        } else {
            session.endAbnormal(withTimestamp: session.started)
        }
        fileManager.deleteCurrentSession()
        // `-[SentryClient captureSession:]` builds exactly this envelope (`SentryClient.m:526-537`);
        // it goes through the hub and transport, so the consent gate still applies.
        PrivateSentrySDKOnly.capture(SentryEnvelope(
            header: SentryEnvelopeHeader.empty(), singleItem: SentryEnvelopeItem(session: session)))
    }

    /// Records when the app resigned active with a session open (the file the SDK's
    /// SessionTracker uses for the same purpose, `SessionTracker.swift` `willResignActive`).
    static func storeLastInForeground(_ date: Date) {
        guard SentrySDK.isEnabled else { return }
        makeFileManager()?.storeTimestampLast(inForeground: date)
    }

    static func deleteLastInForeground() {
        guard SentrySDK.isEnabled else { return }
        makeFileManager()?.deleteTimestampLastInForeground()
    }

    /// Same cache path and DSN hash as the client's own file manager (`SentryClient.m:69-73`).
    private static func makeFileManager() -> SentryFileManager? {
        let container = SentryDependencyContainer.sharedInstance()
        return try? SentryFileManager(
            options: PrivateSentrySDKOnly.options,
            dateProvider: container.dateProvider,
            dispatchQueueWrapper: container.dispatchQueueWrapper)
    }
}
