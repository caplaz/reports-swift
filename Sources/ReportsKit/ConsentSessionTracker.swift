import Foundation
import Sentry
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Starts and ends release-health sessions only while reporting consent is on. Replaces the
/// SDK's SessionTracker (`enableAutoSessionTracking = false`) and keeps its grace period
/// (`SessionTracker.swift:134-215`): resigning active only records the time; becoming active
/// again keeps the session after a short absence and ends it and starts a new one after
/// `sessionInterval` (`Options.sessionTrackingIntervalMillis`, 30 s) or more; terminating
/// ends it. Opting out ends it at once. Crashed sessions are still closed by
/// `SentryCrashIntegrationSessionHandler` from the stored current session
/// (`SentryCrashIntegration.swift:193`, `SentryCrashIntegrationSessionHandler.swift:47-75`),
/// which this tracker keeps current via `SentrySDK.startSession()`.
final class ConsentSessionTracker: @unchecked Sendable {
    static let shared = ConsentSessionTracker()

    private let lock = NSLock()
    private var consented = false
    private var appActive = false
    private var sessionOpen = false
    /// When the app last resigned active with a session open; nil while active.
    private var backgroundedAt: Date?
    private var sessionInterval: TimeInterval = 30
    private var observers: [NSObjectProtocol] = []

    /// Test seams: notification center, the initial "is the app active" probe and the clock.
    var notificationCenter: NotificationCenter = .default
    var isAppActive: () -> Bool = ConsentSessionTracker.defaultIsAppActive
    var now: () -> Date = { Date() }
    static let defaultIsAppActive: () -> Bool = {
        #if os(macOS)
        MainActor.assumeIsolated { NSApplication.shared.isActive }
        #elseif os(iOS)
        MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
        #else
        false
        #endif
    }

    /// Call once after `SentrySDK.start`, on the main thread.
    func install(sessionInterval: TimeInterval) {
        guard lock.withLock({ observers.isEmpty }) else { return }
        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        let willResignActive = NSApplication.willResignActiveNotification
        let willTerminate = NSApplication.willTerminateNotification
        #elseif os(iOS)
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        let willResignActive = UIApplication.willResignActiveNotification
        let willTerminate = UIApplication.willTerminateNotification
        #endif
        #if os(macOS) || os(iOS)
        let tokens = [
            notificationCenter.addObserver(forName: didBecomeActive, object: nil, queue: nil) { [weak self] _ in
                self?.becameActive()
            },
            notificationCenter.addObserver(forName: willResignActive, object: nil, queue: nil) { [weak self] _ in
                self?.resignedActive()
            },
            notificationCenter.addObserver(forName: willTerminate, object: nil, queue: nil) { [weak self] _ in
                self?.terminated()
            },
        ]
        let active = isAppActive()
        lock.withLock {
            observers = tokens
            appActive = active
            self.sessionInterval = sessionInterval
        }
        #endif
    }

    func consentGranted() {
        recoverCachedSessionOnce()
        lock.withLock {
            consented = true
            if appActive { startIfNeeded() }
        }
    }

    private var recoveredCachedSession = false

    /// Once per process, with consent, before this tracker starts its first session (which
    /// would overwrite the stored one): closes the previous launch's unfinished session
    /// (`CachedSessionRecovery`). The cached session was itself created only with consent, and
    /// the cache is deleted at launch when reporting is off.
    private func recoverCachedSessionOnce() {
        let shouldRecover = lock.withLock { () -> Bool in
            defer { recoveredCachedSession = true }
            return !recoveredCachedSession
        }
        guard shouldRecover else { return }
        CachedSessionRecovery.closePreviousLaunchSession()
    }

    /// Ends the open session at once — even inside the grace period — (while the gate is still
    /// open) and blocks new ones.
    func consentRevoked() {
        lock.withLock {
            consented = false
            endIfOpen()
        }
    }

    // State and the SDK's start/end-session calls run under one lock, so a lifecycle
    // notification (posted on any thread) and a consent change never interleave (review
    // finding): a revocation waits for an in-flight start, then ends that session.
    // `SentrySDK.start/endSession` never call back into ReportsKit (sessions skip
    // `beforeSend`), so holding the lock across them cannot deadlock.

    private func becameActive() {
        lock.withLock {
            appActive = true
            if sessionOpen, let since = backgroundedAt {
                let away = now().timeIntervalSince(since)
                // Long absence (or a clock that went backwards): a new session.
                if away >= sessionInterval || away < 0 {
                    SentrySDK.endSession()
                    sessionOpen = false
                }
            }
            clearBackgrounded()
            if consented { startIfNeeded() }
        }
    }

    private func resignedActive() {
        lock.withLock {
            appActive = false
            guard sessionOpen, backgroundedAt == nil else { return }
            let date = now()
            backgroundedAt = date
            // If the process dies in the background, the next launch closes the session as
            // exited at this time rather than abnormal, as the SDK's tracker does.
            CachedSessionRecovery.storeLastInForeground(date)
        }
    }

    private func terminated() {
        lock.withLock {
            appActive = false
            endIfOpen()
        }
    }

    /// Call with `lock` held.
    private func startIfNeeded() {
        guard !sessionOpen else { return }
        beforeStartEffect?()
        SentrySDK.startSession()
        sessionOpen = true
    }

    /// Call with `lock` held.
    private func endIfOpen() {
        if sessionOpen { SentrySDK.endSession() }
        sessionOpen = false
        clearBackgrounded()
    }

    /// Call with `lock` held.
    private func clearBackgrounded() {
        guard backgroundedAt != nil else { return }
        backgroundedAt = nil
        CachedSessionRecovery.deleteLastInForeground()
    }

    /// Test seam: runs inside the lock just before `startSession`.
    var beforeStartEffect: (() -> Void)?

    /// Test-only view of whether a session is currently open.
    var isSessionOpen: Bool { lock.withLock { sessionOpen } }

    func resetForTesting() {
        lock.withLock {
            for observer in observers { notificationCenter.removeObserver(observer) }
            observers = []
            consented = false
            appActive = false
            sessionOpen = false
            backgroundedAt = nil
            sessionInterval = 30
            recoveredCachedSession = false
        }
        notificationCenter = .default
        isAppActive = Self.defaultIsAppActive
        now = { Date() }
        beforeStartEffect = nil
    }
}
