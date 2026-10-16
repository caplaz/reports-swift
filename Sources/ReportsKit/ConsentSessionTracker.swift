import Foundation
import Sentry
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Starts and ends release-health sessions only while reporting consent is on. Replaces the
/// SDK's SessionTracker (`enableAutoSessionTracking = false`). Crashed sessions are still
/// closed by `SentryCrashIntegrationSessionHandler` from the stored current session
/// (`SentryCrashIntegration.swift:193`, `SentryCrashIntegrationSessionHandler.swift:47-75`),
/// which this tracker keeps current via `SentrySDK.startSession()`.
final class ConsentSessionTracker: @unchecked Sendable {
    static let shared = ConsentSessionTracker()

    private let lock = NSLock()
    private var consented = false
    private var appActive = false
    private var sessionOpen = false
    private var observers: [NSObjectProtocol] = []

    /// Test seams: notification center and the initial "is the app active" probe.
    var notificationCenter: NotificationCenter = .default
    var isAppActive: () -> Bool = ConsentSessionTracker.defaultIsAppActive
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
    func install() {
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
                self?.setActive(true)
            },
            notificationCenter.addObserver(forName: willResignActive, object: nil, queue: nil) { [weak self] _ in
                self?.setActive(false)
            },
            notificationCenter.addObserver(forName: willTerminate, object: nil, queue: nil) { [weak self] _ in
                self?.setActive(false)
            },
        ]
        let active = isAppActive()
        lock.withLock {
            observers = tokens
            appActive = active
        }
        #endif
    }

    func consentGranted() {
        recoverCachedSessionOnce()
        transition { $0.consented = true }
    }

    private var recoveredCachedSession = false

    /// Once per process, with consent, before this tracker starts its first session (which
    /// would overwrite the stored one): closes the previous launch's unfinished session as
    /// abnormal (`CachedSessionRecovery`). The cached session was itself created only with
    /// consent, and the cache is deleted at launch when reporting is off.
    private func recoverCachedSessionOnce() {
        let shouldRecover = lock.withLock { () -> Bool in
            defer { recoveredCachedSession = true }
            return !recoveredCachedSession
        }
        guard shouldRecover else { return }
        CachedSessionRecovery.closePreviousLaunchSession()
    }

    /// Ends the open session (while the gate is still open) and blocks new ones.
    func consentRevoked() { transition { $0.consented = false } }

    private func setActive(_ active: Bool) { transition { $0.appActive = active } }

    /// Applies a state change and starts/ends the SDK session so that a session is open
    /// exactly while `consented && appActive`. State and SDK effects run under one lock, so a
    /// lifecycle transition and a consent change can never interleave (review finding): a
    /// revocation waits for an in-flight start, then ends that session. `SentrySDK.start/
    /// endSession` never call back into ReportsKit (sessions skip `beforeSend`), so holding the
    /// lock across them cannot deadlock.
    private func transition(_ change: (ConsentSessionTracker) -> Void) {
        lock.withLock {
            change(self)
            let shouldBeOpen = consented && appActive
            if !shouldBeOpen && sessionOpen { SentrySDK.endSession() }
            if shouldBeOpen && !sessionOpen {
                beforeStartEffect?()
                SentrySDK.startSession()
            }
            sessionOpen = shouldBeOpen
        }
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
            recoveredCachedSession = false
        }
        notificationCenter = .default
        isAppActive = Self.defaultIsAppActive
        beforeStartEffect = nil
    }
}
