import Foundation
import Sentry

/// The only entry point apps use; the only file family that imports Sentry.
public enum CrashReporting {
    /// A handled-error site. Apps declare their own:
    ///
    /// ```swift
    /// extension CrashReporting.Operation {
    ///     static let exportSave = Self("exportSave")
    /// }
    /// ```
    ///
    /// The raw value becomes the `report.op` tag and part of the fingerprint, so it must be a
    /// static identifier written in source code — never user data (file names, paths, text).
    public struct Operation: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuration: CrashReportingConfiguration?
    nonisolated(unsafe) private static var sdkStarted = false
    nonisolated(unsafe) static var preferenceDefaults: UserDefaults = .standard
    nonisolated(unsafe) static var testOptionsOverride: ((Options) -> Void)?
    nonisolated(unsafe) static var logThrottle = LogThrottle()
    nonisolated(unsafe) static var forwardBudget = ForwardBudget()
    nonisolated(unsafe) static var metricBudget = MetricBudget()
    nonisolated(unsafe) static var metricRevocation = MetricRevocation()
    /// `environmentResolver`'s result, once it returns. sentry-cocoa 9.24.0's log scope
    /// applier (`TelemetryScopeApplier.addDefaultAttributes`) sets a log's `sentry.environment`
    /// attribute from `Options.environment` captured at `start`, not from the scope — so
    /// `configureScope { $0.setEnvironment(name) }` (below) affects events but never logs. The
    /// sanitizer reads this value to override the attribute on the log path.
    nonisolated(unsafe) private static var resolvedEnvironment: String?
    /// The profile the SDK started with. sentry-cocoa reads `Options` once, at `start`, so it
    /// is fixed for the rest of the process.
    nonisolated(unsafe) private static var startedProfile: PrivacyProfile = .strict
    /// Set by `setDetailedDiagnosticsEnabled(false)`: the process stays strict from then on,
    /// even if the setting is turned back on (that applies at the next SDK start). Cleared
    /// when the SDK starts.
    nonisolated(unsafe) private static var detailedDiagnosticsRevoked = false

    /// sentry-cocoa 9.24.0 keeps the installation ID — every session's `did` and the default
    /// `user.id` — in this file directly under `Options.cacheDirectoryPath`
    /// (`SentryInstallation.swift`), and generates a new random one when it is missing.
    static let installationFileName = "INSTALLATION"

    /// What the running SDK may send now: `.strict` before the SDK starts; otherwise the
    /// profile it started with, downgraded to `.strict` for the rest of the process once
    /// "Share detailed diagnostics" is turned off (spec §3.4).
    public static var activeProfile: PrivacyProfile {
        let started = lock.withLock { sdkStarted ? startedProfile : .strict }
        return PrivacyProfile.mostPrivate(started, currentSettingProfile())
    }

    /// The profile the detailed-diagnostics setting allows in this process right now:
    /// `.strict` once it was turned off in-process, or while the stored setting is off (which
    /// also catches a direct `CrashReportingPreference.setDetailedDiagnostics(false)` write).
    static func currentSettingProfile() -> PrivacyProfile {
        let revoked = lock.withLock { detailedDiagnosticsRevoked }
        return !revoked && CrashReportingPreference.isDetailedDiagnosticsEnabled(in: preferenceDefaults)
            ? .diagnostic : .strict
    }

    /// Call first thing at launch, **on the main thread** (traps otherwise). With
    /// `enabled == false` the SDK is not started and its cache — reports captured earlier but
    /// never delivered — is deleted; if the deletion fails it stays pending and the next SDK
    /// start completes it before starting (or doesn't start). With `enabled == true` the
    /// profile is `.diagnostic` when both stored settings —
    /// `CrashReportingPreference.isEnabled()` and `isDetailedDiagnosticsEnabled()` — are on,
    /// else `.strict`.
    public static func start(enabled: Bool, configuration: CrashReportingConfiguration) {
        dispatchPrecondition(condition: .onQueue(.main))
        consentTransitionLock.lock()
        defer { consentTransitionLock.unlock() }
        // A launch: unless an SDK is actually running, nothing has started yet. Otherwise a
        // stale `sdkStarted` (SDK closed since) would make `setEnabled(true)` reopen the gate
        // instead of running `startSDK` and its fail-closed cache checks.
        let running = SentrySDK.isEnabled
        lock.withLock {
            Self.configuration = configuration
            if !running {
                sdkStarted = false
                startedProfile = .strict
            }
        }
        if enabled {
            startSDK(configuration)
        } else {
            ConsentGate.shared.setEnabled(false)
            // A failure is recorded by `purgeCache` (pending flag) and retried, fail-closed, by
            // `startSDK` — nothing collected before this opt-out can be sent later.
            purgeCache(configuration.cacheDirectory)
        }
    }

    /// "Send crash reports" toggle. Call **on the main thread** (traps otherwise). Persists the
    /// choice and applies it immediately: off blocks and cancels uploads and never calls
    /// `SentrySDK.close()` (it flushes); on resumes the gate, or starts the SDK in this process
    /// if it isn't running (launched with reporting off).
    public static func setEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        // One ordered transition at a time (review finding): the preference write, consent
        // marker, hang tracking, gate, session effects and trace generation change together.
        // A call made from inside a running transition (on main: an observer or callback
        // reacting synchronously to it) is not run nested — it is queued and applied right
        // after the running one, so overlapping calls end in the state of the last call.
        if transitionRunning {
            pendingTransition = enabled
            return
        }
        transitionRunning = true
        defer { transitionRunning = false }
        var next: Bool? = enabled
        while let value = next {
            pendingTransition = nil
            consentTransitionLock.withLock { applyConsent(value) }
            afterTransitionForTesting?(value)
            next = pendingTransition
        }
    }

    /// Main-thread-only state of `setEnabled`: a transition is running, and the value of the
    /// last call made while it ran (applied when it finishes).
    nonisolated(unsafe) private static var transitionRunning = false
    nonisolated(unsafe) private static var pendingTransition: Bool?

    /// One consent transition. Runs under `consentTransitionLock`.
    private static func applyConsent(_ enabled: Bool) {
        CrashReportingPreference.set(enabled, in: preferenceDefaults)
        guard enabled else {
            // End the consented session first (its final update covers only time while
            // reporting was on), then stop sessions and close the gate. No session starts
            // again until consent returns.
            ConsentSessionTracker.shared.consentRevoked()
            // Consent marker (spec §3.2c): everything collected from now on carries
            // `report.consent=off` in its collection-time scope — including a crash report or a
            // stored hang replayed after re-enable or in a later launch — and `beforeSend` drops
            // it. Set before the gate closes so nothing collected in between escapes it.
            SentrySDK.configureScope {
                $0.setTag(value: CrashReportSanitizer.consentOffValue, key: CrashReportSanitizer.consentTagKey)
            }
            ConsentGate.shared.setEnabled(false)
            // No hang may be detected (and stored, bypassing beforeSend) while opted out. A
            // detection already past its `reportAppHangs` check can finish after re-enable and
            // apply the then-current scope (`SentryHangTrackingIntegration` `anrDetected`), so
            // from the first opt-out on, this process marks every later hang with
            // `report.hangs=off` (never removed in this process; carried into stored hangs and
            // replays) and `beforeSend` drops such hangs. Tracking resumes next launch.
            SentrySDK.configureScope {
                $0.setTag(value: CrashReportSanitizer.consentOffValue, key: CrashReportSanitizer.hangsTagKey)
            }
            SentrySDK.pauseAppHangTracking()
            // Transactions admitted before this point can't be sent any more (spec §3.2d).
            TraceConsent.shared.setConsented(false)
            // Metrics recorded before this opt-out are deleted, never sent (metrics spec §4.2).
            revokePendingMetrics(lock.withLock { Self.configuration })
            return
        }
        let (configuration, started) = lock.withLock { (Self.configuration, sdkStarted) }
        if started && SentrySDK.isEnabled {
            // Fail closed (metrics spec §4.2 "Sweep"): a pre-opt-out metric envelope that can't
            // be deleted, or a cache that can't be listed or read, keeps reporting off for this
            // process; the pending purge empties the cache at the next start (or that start
            // fails closed, as for any required deletion).
            guard let configuration, reopenMetrics(configuration) else {
                CrashReportingPreference.setPendingPurge(true, in: preferenceDefaults)
                return
            }
            beforeConsentMarkerRemovedForTesting?()
            SentrySDK.configureScope { $0.removeTag(key: CrashReportSanitizer.consentTagKey) }
            // App-hang tracking stays paused and `report.hangs=off` stays on the scope for the
            // rest of this process (see the opt-out branch).
            ConsentGate.shared.setEnabled(true)
            TraceConsent.shared.setConsented(true)
            ConsentSessionTracker.shared.consentGranted()
            // The transport only drains its disk queue on a capture, a connectivity change,
            // or a flush; after a gate-refused send it stops. Kick a drain so reports queued
            // while consent was off (but collected while it was on) are delivered now.
            DispatchQueue.global(qos: .utility).async { SentrySDK.flush(timeout: 10) }
        } else if let configuration {
            startSDK(configuration)
        }
    }

    /// Serializes `start` and consent transitions. Every caller is on the main thread (and a
    /// nested `setEnabled` is queued, not run inside), so this never blocks in practice; it is
    /// never held while waiting for the main thread. Recursive in case `startSDK` ever
    /// re-enters.
    private static let consentTransitionLock = NSRecursiveLock()

    /// Test seam: runs inside an enabling transition, before the consent marker is removed.
    nonisolated(unsafe) static var beforeConsentMarkerRemovedForTesting: (() -> Void)?
    /// Test seam: runs on main after each applied transition, with its value.
    nonisolated(unsafe) static var afterTransitionForTesting: ((Bool) -> Void)?

    /// "Share detailed diagnostics" toggle. Call **on the main thread** (traps otherwise).
    /// Persists the choice.
    /// - Off applies immediately: from now on this process sends only what `.strict` allows —
    ///   events, breadcrumbs and logs are sanitized as strict (no error text, paths, breadcrumb
    ///   messages or `user.id`), `forwardLog` stops, and the scope's `report.profile` becomes
    ///   `strict` so crash reports collected from now on are strict when replayed. Release-health
    ///   sessions keep the `did` they started with until the next start (sentry-cocoa can't
    ///   change it in-process). Reports queued before the change (already sanitized when
    ///   captured) are still delivered.
    /// - On applies at the next SDK start (the next launch, or `setEnabled(true)` if the SDK
    ///   isn't running yet); after an in-process off, this process stays strict.
    public static func setDetailedDiagnosticsEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        consentTransitionLock.withLock {
            CrashReportingPreference.setDetailedDiagnostics(enabled, in: preferenceDefaults)
            guard !enabled else { return }
            let running = lock.withLock { () -> Bool in
                // Only a running SDK has diagnostic state to revoke; before start, the stored
                // setting alone decides the profile `startSDK` picks.
                guard sdkStarted else { return false }
                detailedDiagnosticsRevoked = true
                return true
            }
            if running && SentrySDK.isEnabled {
                SentrySDK.configureScope {
                    $0.setTag(value: PrivacyProfile.strict.rawValue, key: CrashReportSanitizer.profileTagKey)
                }
            }
        }
    }

    /// Reports a handled failure as `report.op` + `configuration.describeError(error)`. While
    /// `activeProfile` is `.diagnostic` the exception value also carries
    /// `ErrorDetail.text(for: error)`; grouping (`report.error`, fingerprint) never depends on
    /// the profile. A no-op before `start`, while reporting is off, or when the SDK isn't
    /// running.
    public static func capture(_ error: any Error, operation: Operation) {
        guard let configuration = lock.withLock({ Self.configuration }),
              ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return }
        let detail = activeProfile == .diagnostic ? ErrorDetail.text(for: error) : nil
        SentrySDK.capture(event: makeEvent(
            error: error, operation: operation, describe: configuration.describeError, detail: detail))
    }

    /// The configuration when a log may be sent now: started, consent on, SDK running, and
    /// `logsEnabled`.
    static func canLog() -> CrashReportingConfiguration? {
        guard let configuration = lock.withLock({ Self.configuration }), configuration.logsEnabled,
              ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return nil }
        return configuration
    }

    /// Whether a metric may be recorded now: started, `metricsEnabled`, consent on, SDK running.
    static func canRecordMetric() -> Bool {
        guard let configuration = lock.withLock({ Self.configuration }), configuration.metricsEnabled,
              ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return false }
        return true
    }

    static func makeEvent(
        error: any Error, operation: Operation, describe: (any Error) -> String, detail: String? = nil
    ) -> Event {
        let description = describe(error)
        let event = Event(level: .error)
        let exception = Exception(
            value: detail ?? CrashReportSanitizer.redacted, type: "\(operation.rawValue) \(description)")
        let mechanism = Mechanism(type: "report.handled")
        mechanism.handled = NSNumber(value: true)
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.tags = ["report.op": operation.rawValue, "report.error": description]
        event.fingerprint = ["report", operation.rawValue, description]
        return event
    }

    /// Must run on the main thread: sentry-cocoa 9.24.0 installs the hub synchronously only
    /// when started on main (off-main it dispatches the install asynchronously).
    private static func startSDK(_ configuration: CrashReportingConfiguration) {
        precondition(Thread.isMainThread, "CrashReporting must start on the main thread")
        // Both stored settings (review finding): `start(enabled: true)` is given the app's own
        // flag, which need not match the stored "Send crash reports".
        let requested: PrivacyProfile = CrashReportingPreference.isEnabled(in: preferenceDefaults)
            && CrashReportingPreference.isDetailedDiagnosticsEnabled(in: preferenceDefaults) ? .diagnostic : .strict
        let previous = CrashReportingPreference.lastProfile(in: preferenceDefaults)
        guard prepareCache(configuration.cacheDirectory, profile: requested, previous: previous) else {
            // Fail closed (spec §3.2): a privacy-required deletion failed — a pending purge
            // (opted-out launch or earlier failure), a diagnostic → strict downgrade, or the
            // strict per-launch ID. Don't start the SDK, keep consent closed, and leave
            // `lastProfile` unchanged; the pending-purge flag makes the next start (next launch,
            // or `setEnabled(true)`) retry the full cleanup whatever profile it requests.
            ConsentGate.shared.setEnabled(false)
            lock.withLock {
                sdkStarted = false
                startedProfile = .strict
            }
            return
        }
        CrashReportingPreference.setLastProfile(requested, in: preferenceDefaults)
        metricRevocation.reopen()
        lock.withLock {
            startedProfile = requested
            detailedDiagnosticsRevoked = false
        }
        ConsentGate.shared.setEnabled(true)
        // Tracing consent opens with the gate, before integrations install (review finding:
        // otherwise every launch sampled nothing until a toggle off/on).
        TraceConsent.shared.setConsented(true)
        // `apply` also puts `report.profile = requested` on the initial scope, so every event and
        // every crash/hang report collected by this launch carries it (spec §3.3).
        // `Options.sessionTrackingIntervalMillis` (default 30 s); `start` runs the closure
        // synchronously on main.
        var sessionInterval: TimeInterval = 30
        SentrySDK.start { options in
            apply(configuration, profile: requested, to: options)
            sessionInterval = TimeInterval(options.sessionTrackingIntervalMillis) / 1_000
        }
        lock.withLock { sdkStarted = true }
        ConsentSessionTracker.shared.install(sessionInterval: sessionInterval)
        ConsentSessionTracker.shared.consentGranted()
        if let resolver = configuration.environmentResolver {
            Task.detached(priority: .utility) {
                guard let name = await resolver() else { return }
                lock.withLock { resolvedEnvironment = name }
                SentrySDK.configureScope { $0.setEnvironment(name) }
            }
        }
    }

    /// Runs before `SentrySDK.start`, while nothing has read the installation ID yet.
    /// - A pending purge (reporting was off at a launch, or an earlier purge failed), or
    ///   diagnostic → strict: delete the whole cache — everything collected but not yet sent
    ///   (queued envelopes, the open session, pending crash and hang reports). Runs whatever
    ///   profile is requested.
    /// - Strict: delete `INSTALLATION`, so this launch's sessions get a new random `did`.
    /// - Strict → diagnostic: delete `INSTALLATION` too, so the stable diagnostic ID is new and
    ///   never equals the last strict launch's (already sent) per-launch `did` — otherwise
    ///   opting in would retroactively link that anonymous session (review finding). Cached
    ///   sessions keep the `did` they were created with.
    /// - Diagnostic → diagnostic: keep the stable installation ID.
    /// Returns `false` when a required deletion failed for any reason other than the item
    /// already being absent; the caller then fails closed.
    static func prepareCache(_ directory: URL, profile: PrivacyProfile, previous: PrivacyProfile) -> Bool {
        let downgrade = previous == .diagnostic && profile == .strict
        if downgrade || CrashReportingPreference.hasPendingPurge(in: preferenceDefaults) {
            guard purgeCache(directory) else { return false }
        }
        // Metric envelopes left by a process that opted out (metrics spec §4.2): nothing is
        // sending yet, so this sweep is complete.
        if CrashReportingPreference.hasPendingMetricSweep(in: preferenceDefaults) {
            guard deleteMetricEnvelopes(in: directory) else {
                CrashReportingPreference.setPendingPurge(true, in: preferenceDefaults)
                return false
            }
            CrashReportingPreference.setPendingMetricSweep(false, in: preferenceDefaults)
        }
        let rotateID = profile == .strict || previous == .strict
        guard rotateID else { return true }
        return remove(directory.appendingPathComponent(installationFileName))
    }

    /// Deletes the whole cache directory. The purge is recorded as pending first and cleared
    /// only after the deletion succeeded (absence counts as success), so a failed or
    /// interrupted purge is completed by the next `startSDK`, which fails closed until it is.
    @discardableResult
    static func purgeCache(_ directory: URL) -> Bool {
        CrashReportingPreference.setPendingPurge(true, in: preferenceDefaults)
        guard remove(directory) else { return false }
        CrashReportingPreference.setPendingPurge(false, in: preferenceDefaults)
        CrashReportingPreference.setPendingMetricSweep(false, in: preferenceDefaults)
        return true
    }

    /// `true` when `url` is gone afterwards: deleted now, or already absent.
    static func remove(_ url: URL) -> Bool {
        do {
            try removeItem(url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone: nothing to clean.
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // Already gone.
        } catch {
            return false
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletion seam for failure-injection tests; production always uses `FileManager`.
    nonisolated(unsafe) static var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    static func apply(
        _ configuration: CrashReportingConfiguration, profile: PrivacyProfile = .strict, to options: Options
    ) {
        options.dsn = configuration.dsn
        options.releaseName = configuration.releaseName
        options.environment = configuration.environment
        options.cacheDirectoryPath = configuration.cacheDirectory.path
        options.sendDefaultPii = false
        // Release-health sessions in both profiles, driven by `ConsentSessionTracker` instead of
        // the SDK's SessionTracker: auto tracking keeps starting sessions on foreground while
        // the user has opted out (only the transport is gated), and `captureSession` bypasses
        // `beforeSend`, so those sessions would upload on re-enable (review finding). Their
        // `did` is the installation ID, which `prepareCache` makes random per launch in strict.
        options.enableAutoSessionTracking = false
        options.enableAppHangTracking = true
        // Tracing is gated by consent with clock-free provenance (spec §3.2d): a transaction is
        // sampled (the SDK rolls `rate`) only while consent is on, and its identity is admitted
        // to the current consent generation; revocation clears the generation, and
        // `beforeSend` sends a transaction only if its identity is still admitted. A
        // transaction created with an explicit `sampled` decision skips `tracesSampler`
        // (`SentrySampling.m` `sentry_sampleTrace`), is never admitted, and is dropped. Covers transactions started while
        // off (never sampled) and ones spanning or finishing during an opted-out interval,
        // even when their processing runs after re-enable (`SentryHub.m:335-360`).
        // Only with a positive rate: a sampler alone turns tracing on (`Options.isTracingEnabled`)
        // and installs the tracing integrations, which a 0 rate kept off before.
        let rate = configuration.tracesSampleRate
        if rate > 0 {
            options.tracesSampler = { context in
                TraceConsent.shared.admit(
                    key: TraceConsent.key(
                        traceID: context.transactionContext.traceId, spanID: context.transactionContext.spanId),
                    rate: rate)
            }
        }
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        // Default true installs SentryNetworkTrackingIntegration and swizzles URLSessionTask
        // app-wide; failed requests from the app's own URLSessions would otherwise become
        // events (with their URLs).
        options.enableCaptureFailedRequests = false
        options.sendClientReports = false
        // Metric batches are envelopes too (one per ≤ 5 s of activity). With the default 30, a
        // few minutes offline would evict queued handled errors, logs and sessions (oldest first,
        // `SentryFileManager.handleEnvelopesLimit`) (metrics spec §6).
        options.maxCacheItems = 100
        // Collection-time profile marker (spec §3.3). On the initial scope, so it is in place
        // before any integration installs: SentryCrash snapshots it into every crash report and
        // stored app hangs carry it from detection. `beforeSend` reads it back.
        options.initialScope = { scope in
            scope.setTag(value: profile.rawValue, key: CrashReportSanitizer.profileTagKey)
            return scope
        }
        // Metrics in both profiles (metrics spec decision 1); only ReportsKit's own declared
        // metrics pass `beforeSendMetric` below. sentry-cocoa's default is on.
        options.enableMetrics = configuration.metricsEnabled
        options.enableLogs = configuration.logsEnabled
        #if os(iOS)
        // UIKit-only options in sentry-cocoa 9.24.0 (absent from the macOS slice).
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        #endif
        #if os(macOS)
        // AppKit swallows uncaught main-thread NSExceptions otherwise; Sentry recommends
        // enabling this on macOS.
        options.enableUncaughtNSExceptionReporting = true
        #endif

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ConsentURLProtocol.self]
        options.urlSession = URLSession(configuration: sessionConfiguration)

        options.beforeSend = { event in
            guard ConsentGate.shared.isEnabled else { return nil }
            // Collected while opted out (a crash during an in-session opt-out, or a hang stored
            // before the pause took effect, replayed after re-enable or in a later launch): its
            // collection-time scope carried the consent marker. Never sent (spec §3.2c).
            if event.tags?[CrashReportSanitizer.consentTagKey] == CrashReportSanitizer.consentOffValue { return nil }
            if CrashReportSanitizer.isAppHang(event),
               event.tags?[CrashReportSanitizer.hangsTagKey] == CrashReportSanitizer.consentOffValue { return nil }
            // Root identity from the transaction itself: `contexts.trace` at this point is the
            // scope's bound span / propagation context (`SentryScope.m:690-723`), replaced by the
            // transaction's own trace only in `serialize` (`SentryTransaction.m:108`).
            if event.type == "transaction", !TraceConsent.shared.consume(key: TraceConsent.rootKey(of: event)) {
                return nil
            }
            // Also no more detail than the current setting allows (detailed diagnostics turned
            // off in this process applies at once).
            let applied = PrivacyProfile.mostPrivate(eventProfile(for: event, started: profile), currentSettingProfile())
            // The tag sent is the profile actually applied, not the one claimed at collection.
            var tags = event.tags ?? [:]
            tags[CrashReportSanitizer.profileTagKey] = applied.rawValue
            event.tags = tags
            return CrashReportSanitizer.sanitize(event, profile: applied)
        }
        options.beforeBreadcrumb = { breadcrumb in
            guard ConsentGate.shared.isEnabled else { return nil }
            return CrashReportSanitizer.sanitize(
                breadcrumb, profile: PrivacyProfile.mostPrivate(profile, currentSettingProfile()))
        }
        options.beforeSendLog = { log in
            guard ConsentGate.shared.isEnabled else { return nil }
            let environment = lock.withLock { resolvedEnvironment }
            return CrashReportSanitizer.sanitize(
                log: log, expected: PendingLog.current, environment: environment,
                profile: PrivacyProfile.mostPrivate(profile, currentSettingProfile()))
        }
        options.beforeSendSpan = { span in
            CrashReportSanitizer.sanitize(span: span)
            return span
        }
        // Runs synchronously on the recording thread after scope application
        // (`SentryMetricsIntegration.swift:44-78`): the live gate and the pending metric are
        // authoritative, so no consent marker is needed (metrics spec §4.1).
        options.beforeSendMetric = { metric in
            guard ConsentGate.shared.isEnabled, let pending = PendingMetric.current,
                  !metricRevocation.isRevoked(pending.timestamp) else { return nil }
            let environment = lock.withLock { resolvedEnvironment }
            return CrashReportSanitizer.sanitize(
                metric: metric, expected: pending, environment: environment,
                profile: PrivacyProfile.mostPrivate(profile, currentSettingProfile()))
        }
        testOptionsOverride?(options)
    }

    /// The more private of the profile this SDK started with and the profile the event was
    /// collected under — its own `report.profile` tag; missing or unknown = strict (spec §3.3).
    /// Live events get the tag from this launch's scope. Stored events from an earlier launch
    /// (crash reports, app hangs, watchdog terminations — replayed at any level, possibly
    /// several launches later) carry the tag of the scope that collected them, and the current
    /// scope never replaces it: fatal events skip scope application (`SentryClient.m:778-784`),
    /// stored hangs replay with an empty `Scope()` (`SentryHangTrackingIntegration.swift:161,181`),
    /// and where a scope is applied the event's own tags win (`SentryScope.m:635-642`). Neither
    /// timestamps nor levels are consulted, so clock changes can't promote strict data.
    static func eventProfile(for event: Event, started: PrivacyProfile) -> PrivacyProfile {
        let collected = event.tags?[CrashReportSanitizer.profileTagKey].flatMap(PrivacyProfile.init(rawValue:)) ?? .strict
        return PrivacyProfile.mostPrivate(started, collected)
    }

    /// Test-only: close the SDK and forget state. `close()` flushes, so callers must have
    /// the network stubbed.
    static func resetForTesting() {
        forwardQueue.sync {}   // no forwarded log from the previous test may reach the next SDK
        metricQueue.sync {}   // likewise for metrics
        ConsentSessionTracker.shared.resetForTesting()
        TraceConsent.shared.resetForTesting()
        beforeConsentMarkerRemovedForTesting = nil
        afterTransitionForTesting = nil
        SentrySDK.close()
        ConsentGate.shared.setEnabled(false)
        lock.withLock {
            configuration = nil
            sdkStarted = false
            resolvedEnvironment = nil
            startedProfile = .strict
            detailedDiagnosticsRevoked = false
        }
        testOptionsOverride = nil
        resetFileSeamsForTesting()
        preferenceDefaults = .standard
        logThrottle = LogThrottle()
        forwardBudget = ForwardBudget()
        metricBudget = MetricBudget()
        metricRevocation = MetricRevocation()
        ConsentURLProtocol.afterVerdictForTesting = nil
    }
}
