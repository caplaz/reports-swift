# Privacy profiles (ReportsKit 0.3.0 + PatternSpace) — design

Date: 2026-10-16
Status: approved (owner: Stefano), pending implementation
Repos: `caplaz/reports-swift` (module `ReportsKit`, today 0.2.2) and PatternSpace (`main`).
Plan: `docs/superpowers/plans/2026-10-16-privacy-profiles.md` (PatternSpace repo).

## Goal

Let a user who wants to help opt in to **detailed diagnostics** — error text, file names,
the app's full log, a stable installation identifier, release-health sessions — while the
default stays exactly as private as today, plus crash-free-session counts that carry no
stable identifier.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Profiles | `ReportsKit` gains `CrashReporting.PrivacyProfile`: `.strict` (default, today's behavior + ID-free sessions) and `.diagnostic`. |
| 2 | What `.diagnostic` adds | Raw error text and file names/paths (handled errors carry the error's own text; the sanitizer keeps exception values, frame file names and full image paths), **all** app logs at info and above forwarded to Sentry Logs with level + category, sessions with the installation ID (Crash Free Sessions + Crash Free Users), Sentry metrics enabled. Never: device/computer name, IP address, screenshots, view hierarchy. |
| 3 | Strict sessions | Enabled, with a **per-launch random** `did` (verdict below: possible in sentry-cocoa 9.24.0 by deleting the SDK's `INSTALLATION` file before start). |
| 4 | Selection | **User setting**, not environment. A second toggle "Share detailed diagnostics", shown in all builds, **off by default everywhere** (TestFlight included). `.diagnostic` only when "Send crash reports" **and** "Share detailed diagnostics" are both on at SDK start; otherwise `.strict`. Profile is fixed at SDK start (sentry-cocoa reads options once), so a change applies at next launch. No cached-environment mechanism. **No configuration override** (see §5.4). |
| 5 | Logs | `PatternSpaceLog` returns a wrapper type with `os.Logger` call syntax; it writes to the unified log and, when a forwarder is installed, hands the rendered message + level + category to it. The app installs a forwarder that calls `CrashReporting.forwardLog(_:category:message:)` (diagnostic only, consent-gated, budgeted). Info and above only. |
| 6 | Opt-out | "Send crash reports" off stops everything immediately in every profile (transport consent gate, session end, hang-tracking pause, `report.consent=off` scope marker so nothing collected while off is sent later). Reporting off at launch purges the cache; a failed purge stays pending and blocks the next SDK start until it succeeds. The detailed toggle is disabled (greyed) while reporting is off. |
| 7 | Disclosures | Settings footers per toggle (4 locales + English), privacy.html, App Store privacy label (must change: optional collection is still collection), Help quickstart (5 locales), CHANGELOG. |
| 8 | Versions | ReportsKit 0.3.0 (additive; default strict). PatternSpace pins `exact: "0.3.0"`. |

## 1. What each profile sends

| Data | `.strict` | `.diagnostic` |
|---|---|---|
| Crashes, hangs, handled errors | yes, sanitized (today) | yes, with error text + paths |
| Handled-error text | `describeError` only (`report.error` tag, exception type) | same tag/type/fingerprint **plus** exception value = `ErrorDetail.text(error)` |
| Stack frames / images | function, address, image last path component | + frame `fileName`, full image `package` / `code_file` paths |
| `CrashReporting.log` (app's explicit logs) | today | + `report.error.detail` attribute on the error variant |
| Forwarded app logs | none | every `PatternSpaceLog` message at info+, `report.category`, budgeted |
| Release-health sessions | yes, `did` random per launch | yes, `did` = installation ID |
| Installation ID on events/logs | stripped | kept as `user.id` (only field of `user`) |
| Metrics | `enableMetrics = false` | `enableMetrics = true`, gated `beforeSendMetric` (no producer yet; §8) |
| Device/computer name, IP, screenshots, view hierarchy, request data, `extra`, server name | never | never |
| Tag `report.profile` | `strict` | `diagnostic` |

## 2. Session verdict — strict CAN send sessions without a stable `did`

Paths relative to `reports-swift/.build/checkouts/sentry-cocoa/Sources` (9.24.0).

- The session `did` is always the installation ID: `SentryHub startSession` builds
  `distinctId = [SentryInstallation idWithCacheDirectoryPath:options.cacheDirectoryPath]` and
  passes it to `initWithReleaseName:distinctId:` — `Sentry/SentryHub.m:107-111`. Scope
  application to sessions copies only the environment — `Sentry/SentryScope.m:609-616` (no
  user id path).
- A session cannot be changed after creation: `_distinctId` is private, the public
  `distinctId` is read-only — `Swift/SentrySession.swift:24,40-46,297-299`; it is serialized as
  `did` — `:241`.
- No callback sees a session before send: `SentryClient captureSession:` wraps it in an
  envelope with an empty header and calls `captureEnvelope:` directly — no `beforeSend` —
  `Sentry/SentryClient.m:526-537`. (README already documents "session envelopes bypass
  `beforeSend`".)
- **But the source of the ID is a file ReportsKit owns.** `SentryInstallation.id(withCacheDirectoryPath:)`
  returns the per-process in-memory value for that path, else reads
  `<cacheDirectoryPath>/INSTALLATION`, else generates `UUID().uuidString` and writes it —
  `Swift/Helper/SentryInstallation.swift:18-41,73-75`; the in-memory cache is a static
  per-process dictionary — `:11`. The first read happens after `SentrySDK.start` builds the
  client (`cacheIDAsync`, `Sentry/SentryClient.m:156`) or at the first `startSession`
  (`SentryHub.m:107-108`). `cacheDirectoryPath` is `CrashReportingConfiguration.cacheDirectory`
  (ReportsKit sets it; the app owns the directory).

**Verdict:** in `.strict`, ReportsKit deletes `<cacheDirectory>/INSTALLATION` immediately
before `SentrySDK.start` (main thread, first SDK call in the process). The SDK then
generates a fresh random UUID for this launch and uses it as `did` for every session of
the launch. Sessions are linkable within one launch only (on iOS a launch can have several
foreground sessions), never across launches. Events and logs carry the same per-launch ID as
`user.id`, which the strict sanitizer already strips (`SentryClient.m:979-992` via `:814`;
`Swift/Tools/TelemetryScopeApplier/TelemetryScopeApplier.swift:128-146`).

Consequences, accepted: Crash Free **Sessions** is accurate for strict installs; Crash Free
**Users** and user counts treat each strict launch as a new user (inflated), so they are
only meaningful for diagnostic installs. Sessions carry only `sid` (random), `did`,
`started`, `timestamp`, `duration`, `status`, `errors`, `seq`, `init`, `attrs.release`,
`attrs.environment`, `abnormal_mechanism` (`SentrySession.swift` serialize) — no device data.

Relies on 9.24.0 internals (file name `INSTALLATION`, per-path cache). Covered by an
envelope-level test that plants a known `INSTALLATION` value and asserts the strict session
`did` differs from it and the diagnostic `did` equals it; the exact pin + "re-run tests on
bump" rule already applies.

Auto session tracking needs an active app: `SessionTracker.start` subscribes to
`didBecomeActive` and starts immediately only if the app is already active —
`Swift/Integrations/Session/SessionTracker.swift:45-75`; the integration installs only when
`enableAutoSessionTracking` — `SentryAutoSessionTrackingIntegration.swift:11-24`. In the
`swift test` runner no app becomes active, so tests start sessions with the public
`SentrySDK.startSession()` (`Swift/Helper/SentrySDK.swift:530`), the same `SentryHub startSession` path.

## 3. Profile selection and lifecycle

### 3.1 Preferences (ReportsKit, generic)

- Existing `CrashReportingPreference.key = "crashReportingEnabled"` (default on).
- New `CrashReportingPreference.detailedDiagnosticsKey = "crashReportingDetailedDiagnostics"`
  (default **off**): `isDetailedDiagnosticsEnabled(in:)`, `setDetailedDiagnostics(_:in:)`.
- New internal `lastProfileKey = "crashReportingLastProfile"`: the profile the SDK last
  started with (raw value), written at every SDK start.
- New internal `pendingPurgeKey = "crashReportingPendingPurge"`: a whole-cache purge was
  requested and has not completed. Set before deleting, removed only after the deletion
  succeeded (an already-absent directory counts as success).

### 3.2 At SDK start (`start(enabled: true, …)` or `setEnabled(true)` starting the SDK)

1. `requested = detailedDiagnostics ? .diagnostic : .strict` (start only runs with reporting on).
2. `previous = lastProfile ?? .strict`.
3. Cache preparation, before `SentrySDK.start`:
   - a pending purge exists, **whatever `requested` is**, or `previous == .diagnostic &&
     requested == .strict` → delete the whole cache directory (everything collected but not
     yet sent — queued envelopes, the open session, pending crash and hang reports — is
     discarded). The purge is marked pending first and cleared only on success.
   - then, if `requested == .strict` → delete `INSTALLATION` (per-launch `did`).
   - `requested == .diagnostic` → keep it (stable ID; the first diagnostic launch adopts the
     file left by the previous launch, or creates one).
   Cache preparation **fails closed**: if a required deletion fails for any reason other
   than the item already being absent, the SDK is not started, consent stays closed and
   `lastProfile` is not advanced; the pending flag makes the next start (next launch or
   `setEnabled(true)`) retry the full purge even if it requests `.diagnostic`.
4. Write `lastProfile = requested`; set `activeProfile = requested`.
5. `SentrySDK.start` with options for `requested`; `Options.initialScope` sets scope tag
   `report.profile = requested` before any integration installs (§3.3).

`start(enabled: false)` closes the gate and purges the cache through the same pending-flag
path, so a deletion that fails during an opted-out launch is not forgotten: turning
reporting on later (with or without detailed diagnostics) starts nothing until the purge
has succeeded.

### 3.2b Sessions follow consent

`enableAutoSessionTracking = false` in both profiles. The SDK's SessionTracker would keep
starting sessions on foreground while the user has opted out (only the transport is gated)
and `captureSession` bypasses `beforeSend`, so those sessions would upload on re-enable.
ReportsKit's `ConsentSessionTracker` opens a session exactly while consent is on and the app
is active: on opt-out it ends the open session first (its final update covers only consented
time), then closes the gate; nothing starts while off; re-enable starts a new session.
Crashed sessions are still closed by the SDK's crash integration from the stored session.
State changes and the SDK's start/end-session calls run under one lock, so a lifecycle
transition can't race a revocation and leave a session open while opted out.

### 3.2c Consent marker and session recovery

- Opt-out sets scope tag `report.consent = off` (before the gate closes) and pauses app-hang
  tracking (`SentrySDK.pauseAppHangTracking`); re-enable removes the tag and resumes.
  `beforeSend` drops any event whose own tags carry `report.consent = off`. The marker is a
  collection-time fact that travels with stored data exactly like `report.profile` (§3.3) —
  synced into crash reports, applied to stored hangs at detection, persisted for watchdog
  terminations — so a crash during an in-session opt-out, or a hang stored just before the
  pause, is dropped when it is replayed after re-enable or in a later launch. No wall-clock
  comparison is involved. The sanitizer never sends `report.consent` (not in the tag
  allowlist). An opted-out *launch* needs no marker: the SDK isn't running and the cache is
  purged (§3.2).
- Manual session tracking still closes a previous launch's unfinished (force-quit, SIGKILL)
  session as abnormal, once per process, only with consent, before the first session of the
  launch. sentry-cocoa does this in `SessionTracker.endCachedSession` →
  `-[SentryHub closeCachedSessionWithTimestamp:]` (`Swift/Integrations/Session/SessionTracker.swift:113-121`,
  `Sentry/SentryHub.m:197-229`), but `SentrySDK.currentHub()` is not in the 9.24.0 binary's
  public or SPI Swift interface (only `PrivateHeaders/SentrySDK+Private.h:61`, not exported by
  the module map), so a selector call on it doesn't compile. ReportsKit's
  `CachedSessionRecovery` re-implements the method's no-timestamp branch with SPI that the
  shipped `Sentry.framework/Modules/Sentry.swiftmodule/*.private.swiftinterface` does export
  (`@_spi(Private) import Sentry`, one file): skip when `SentrySDK.lastRunStatus == .didCrash`
  (the crash integration already closed it; `Sentry/SentrySDKInternal.m:503-512`); build a
  `SentryFileManager(options: PrivateSentrySDKOnly.options, dateProvider:, dispatchQueueWrapper:)`
  from `SentryDependencyContainer.sharedInstance()` (same path and DSN hash as the client's,
  `Sentry/SentryClient.m:69-73`); `readCurrentSession()`, `endAbnormal(withTimestamp: started)`,
  `deleteCurrentSession()`; send it with `PrivateSentrySDKOnly.capture(SentryEnvelope(header:
  .empty(), singleItem: SentryEnvelopeItem(session:)))`, the envelope
  `-[SentryClient captureSession:]` builds (`Sentry/SentryClient.m:526-537`), through the
  gated transport. Type-checked against the macOS and iOS slices with `-warnings-as-errors`
  (2026-10-16); an envelope test (force-quit relaunch → `abnormal` session with the first
  launch's `sid`) guards it, and any SPI change on a bump breaks the build.

### 3.3 Events from earlier launches — collection-time profile marker

SentryCrash, app-hang and watchdog reports are written during launch N and sanitized when
sent during a later launch — not necessarily N+1: crash reports are processed
asynchronously (`SentryCrashReportSink.m`), so a report can be replayed several launches
after it was collected. Provenance is decided by a **marker recorded at collection time**,
not by severity (sentry-cocoa replays stored app hangs at `.error` after
`crashedLastLaunch`, `Swift/Integrations/AppHangTracking/SentryHangTrackingIntegration.swift:175-181`)
and not by timestamps (a wall-clock rollback would make a strict-launch crash look newer
than a later opt-in).

Every SDK start puts `report.profile = <started profile>` on the scope through
`Options.initialScope`, which the SDK applies when it creates the hub, before integrations
install (`Swift/Options.swift:282`, `Sentry/SentrySDKInternal.m:251-252,267-274`). Then:

`eventProfile = mostPrivate(started, collected)`, where `collected` is the event's own
`report.profile` tag; missing or unknown → `.strict`. `beforeSend` rewrites the tag to the
applied profile, so what Sentry shows is what was applied. Verified in 9.24.0 (paths under
`Sources/`):

- **(a) Crash reports carry the crash-time tags.** At install SentryCrash snapshots the whole
  scope (incl. tags) into its user info and registers `SentryCrashScopeObserver` for later
  changes (`Swift/Integrations/SentryCrash/SentryCrashIntegration.swift:223-251`); tag changes
  are synced to the crash-time scope store (`Sentry/SentryCrashScopeObserver.m:62-66`). The
  converter merges both into `userContext` (`Sentry/SentryCrashReportConverter.m:47-60`) and
  sets `event.tags = userContext[@"tags"]` (`:148`). The replayed event is captured as fatal
  (`Sentry/SentryCrashReportSink.m:94-102` → `Sentry/SentryHub.m:271-273` sets
  `isFatalEvent`), and the client does **not** apply the current scope to fatal events
  (`Sentry/SentryClient.m:336-338,778-784`; `Sentry/SentryScope.m:628-633`). An untagged
  report (e.g. from ReportsKit 0.2.x) stays untagged → strict.
- **(b) Stored app hangs carry their detection-time tags.** On iOS the hang event gets the
  then-current scope applied before it is stored (`SentryHangTrackingIntegration.swift:118-124`);
  replays use an empty `Scope()` (`:161`, `:181`) or the fatal path (`:187-200` →
  `Sentry/SentryHub.m:300-303`), so the current scope adds nothing. On macOS a hang is
  captured live (`:125-126`) with this launch's scope — correctly this launch's profile.
  Watchdog terminations are built from the previous run's persisted tags
  (`Swift/Integrations/WatchdogTerminations/SentryWatchdogTerminationTracker.swift:67`) and
  captured as fatal (`:83`).
- **(c) Where the current scope is applied, the event's own tags win.** `applyToEvent`
  starts from the scope's tags and overlays the event's
  (`Sentry/SentryScope.m:635-642`), before `beforeSend` (`Sentry/SentryClient.m:783,848`). So
  an event that already carries `report.profile = strict` can't be relabelled by a diagnostic
  scope. The scope does *fill in* a missing tag on a non-fatal event — which only happens
  for live events of this launch (every replay path above bypasses the current scope), where
  the started profile is correct.

Consequences: strict-collected data is never sent with diagnostic detail after an opt-in,
whatever the clock did; diagnostic-collected data replayed in a diagnostic launch keeps its
detail; diagnostic-collected data replayed in a strict launch is strict (and normally purged
first, §3.2). A crash in the instant before `initialScope` is applied would be untagged and
therefore strict. Relies on 9.24.0 internals (exact pin; envelope tests replay tagged and
untagged events without the current scope, the way the SDK does).

### 3.4 Changes during a run

- Detailed toggle: persisted only; the running SDK keeps its profile; UI footer says
  "Takes effect the next time you open PatternSpace".
- "Send crash reports" off: consent gate closes immediately (all profiles, all telemetry
  incl. sessions, forwarded logs and metrics — same transport). On again: same profile resumes.
- Launched with reporting off, later turned on: the SDK starts then with the profile from
  the stored detailed preference (the user sees both toggles on, so this matches the UI) —
  after completing the launch's cache purge if it failed earlier; if it still fails, the SDK
  stays off and the next start retries.

### 3.5 Why no configuration override

An app-level `profileOverride` would be one line, but it would let an integrator ship
diagnostic collection without the user's opt-in, which is the one thing a privacy library
should make impossible. Tests drive the profile through `preferenceDefaults` instead. Not added.

## 4. ReportsKit 0.3.0 public API additions

```swift
extension CrashReporting {
    public enum PrivacyProfile: String, Sendable, CaseIterable { case strict, diagnostic }
    /// The profile the running SDK started with; `.strict` when the SDK isn't running.
    public static var activeProfile: PrivacyProfile { get }
    /// Persists the "Share detailed diagnostics" choice; applies at the next SDK start.
    public static func setDetailedDiagnosticsEnabled(_ enabled: Bool)

    public enum ForwardedLogLevel: Sendable { case info, warning, error, fatal }
    /// Diagnostic profile only: forwards one app log line. No-op otherwise.
    public static func forwardLog(_ level: ForwardedLogLevel, category: String, message: String)
}
extension CrashReportingPreference {
    public static let detailedDiagnosticsKey: String   // "crashReportingDetailedDiagnostics"
    public static func isDetailedDiagnosticsEnabled(in: UserDefaults = .standard) -> Bool  // default false
    public static func setDetailedDiagnostics(_: Bool, in: UserDefaults = .standard)
}
```

Unchanged signatures: `start`, `setEnabled`, `capture`, `log`, `CrashReportingConfiguration`.
Internal signatures gain a defaulted `profile:` parameter (`apply(_:profile:to:)`,
`CrashReportSanitizer.sanitize(_:profile:)`, `sanitize(log:expected:environment:profile:)`)
so existing tests compile unchanged and keep pinning strict behavior.

## 5. Sanitizer rules per profile

Events (`beforeSend`):

| Field | strict | diagnostic | Reason |
|---|---|---|---|
| `user` | nil | `User(userId:)` copied from the SDK's installation-ID user, nothing else | the install ID is the opted-in identifier; email/username/IP/geo/data never |
| `exception.value` | `<redacted>` | kept | crash reason / `ErrorDetail` text is the main point of diagnostic mode |
| `mechanism.desc`, `mechanism.data` | nil | kept | NSException userInfo/reason context; `meta` (signal/Mach codes) kept in both |
| `mechanism.helpLink` | nil | nil | SDK docs URL, no diagnostic value |
| frame `fileName` | nil | kept | build-machine source path; useful when present |
| frame `package`, image `code_file` | last path component | full path | install location, container path — the "paths" decision |
| frame `contextLine`/`pre`/`postContext`/`vars` | nil | nil | not produced on Apple platforms; `vars` could hold values |
| `message`, `extra`, `request`, `error`, `modules`, `logger` | nil | nil | no producer in ReportsKit (we build our own events); unknown content stays out |
| `serverName` | nil | nil | host/computer name |
| tags | `report.op`, `report.error`, `report.profile` | same | SDK/integration tags are not reviewed |
| contexts | today's allowlist | same | `device.name`, `culture`, `device_app_hash` stay out; no new need |
| breadcrumb `message` | nil | kept | system/lifecycle text (memory warnings, orientation); network breadcrumbs stay disabled |
| breadcrumb `data` | `screen`, `state` | same | keys are unbounded |
| spans/transactions | today | same | tracing producers for file/network are disabled; nothing to gain |

Logs (`beforeSendLog`): a log is kept only if it matches the log ReportsKit is emitting on
this thread (`PendingLog`, unchanged mechanism) **and** its `report.source` is allowed for
the profile: strict `{"reportskit"}`, diagnostic `{"reportskit", "app-log"}`. Attributes
are rebuilt from the expected log (filtered to the profile's keys) plus the SDK allowlist:

| Attribute | strict | diagnostic |
|---|---|---|
| SDK allowlist (release, environment, SDK, OS, device brand/model/family) | kept | kept |
| `user.id` (installation ID) | stripped | kept |
| `report.op`, `report.error`, `report.source` | kept | kept |
| `report.error.detail`, `report.category`, `report.dropped` | stripped | kept |
| everything else (`user.name/email`, replay ids, templates, scope attributes) | stripped | stripped |

The forwarded log's original timestamp (caller thread) replaces the SDK's (queue thread).
Strict output is byte-for-byte today's: the existing strict sanitizer tests stay unchanged.

Metrics (`beforeSendMetric`, diagnostic only): dropped while the gate is closed; otherwise
passed through (no producer exists yet).

## 6. Logs

### 6.1 `CrashReporting.log` (unchanged API)

Diagnostic adds `report.error.detail = ErrorDetail.text(error)` to the error variant. Body,
`report.error`, throttle key and level are unchanged in both profiles, so grouping and
dedupe do not depend on the profile.

### 6.2 `CrashReporting.forwardLog`

- No-op unless `activeProfile == .diagnostic` and `canLog()` (started, `logsEnabled`, gate
  open, SDK enabled).
- Body = message truncated to 4,096 characters (+ "…").
- Budget (`ForwardBudget`, injectable monotonic clock): identical `(level, category, body)`
  at most once per 10 s; at most 120 per rolling 60 s window; at most 5,000 per process.
  Dropped lines are counted; the next admitted line carries `report.dropped = "<n>"`.
- Admission on the caller's thread (cheap: two locks), emission on a serial utility queue
  (`io.caplaz.ReportsKit.forwardLog`) inside `PendingLog.with`, so DeckLink completion
  threads never run SDK scope application. The queue re-checks the gate before emitting.
- Levels: `info → info`, `warning → warn`, `error → error`, `fatal → fatal`
  (`SentryLogger` String overloads, `Swift/Tools/SentryLogger.swift:106-176`, add no template
  attributes). Attributes: `report.source = "app-log"`, `report.category`, optional `report.dropped`.

### 6.3 Volume and quota

Worst case 5,000 × ~4 KB ≈ 20 MB per launch; realistic launches emit tens to a few hundred
lines (107 call sites, mostly errors; per-patch `SDI.Frames` notices and per-frame DeckLink
errors are what the per-key and per-minute caps are for). Only users who opt in send any.
The SDK batches up to 100 logs per envelope every 5 s. Watch the Sentry plan's log quota
after the first beta; caps are constants in `ForwardBudget` if they need tuning.

## 7. PatternSpace logging wrapper

### 7.1 Shape (PatternSpaceCore, no ReportsKit dependency)

```swift
public struct PatternSpaceLogger: Sendable {
    public let category: String
    public func debug/trace(_ message: PatternSpaceLogMessage)          // unified log only
    public func info/notice/warning/error/critical/fault(_ message: PatternSpaceLogMessage)
    public func log(_ message: PatternSpaceLogMessage)                   // = notice
    public func log(level: OSLogType, _ message: PatternSpaceLogMessage)
}
public struct PatternSpaceLogMessage: ExpressibleByStringInterpolation, Sendable { public let rendered: String }
public enum PatternSpaceLogPrivacy: Sendable { case `public`, `private`, sensitive, auto }
extension PatternSpaceLog {
    public static func logger(forCategory:) -> PatternSpaceLogger   // was os.Logger
    public static func logger(_ category: Category) -> PatternSpaceLogger
    public static let sdi, sdiFrames: PatternSpaceLogger
    public enum ForwardLevel: Sendable { case info, notice, warning, error, critical, fault }
    public typealias Forwarder = @Sendable (ForwardLevel, _ category: String, _ message: String) -> Void
    public static func setForwarder(_ forwarder: Forwarder?)
    public static var hasForwarder: Bool { get }
}
```

The interpolation supports exactly what the call sites use (verified by grep: 107 calls —
62 `error`, 40 `notice`, 5 `debug`, plus `log(level:)` in `mirror`; no `format:` or `align:`
anywhere; interpolations are `String` with `privacy: .public` or integers without a privacy
argument): `String`, `BinaryInteger`, `BinaryFloatingPoint`, `Bool`, and generic
`CustomStringConvertible`, each with `privacy:` defaulting to `.auto` and taken as an
`@autoclosure` (a redacted value is never evaluated). Defaults mirror os: under `.auto`,
scalars (integers, floats, Bool) are shown and strings/objects are redacted. All 107 call
sites compile unchanged; only `PatternSpaceLog.swift` changes.

### 7.2 Unified-log side and trade-off

`OSLogMessage` can only be built by the compiler from a literal interpolation; there is no
API to build one from a runtime `String` with per-argument privacy. So the wrapper renders
eagerly: private/sensitive (and `.auto` non-scalar) arguments become the literal
`<private>`, and the line is written as `base.log(level:, "\(rendered, privacy: .public)")`
with the same subsystem and category.

- **Preserved:** subsystem, category, level (debug/info/default/error/fault), `log collect`,
  Console filtering by subsystem/category/level, `DiagnosticsLogReader` (reads
  `composedMessage`, notice+ — identical text for all-public messages, which is every current
  call site), the "values are public at the call site" convention.
- **Lost:** a private argument can no longer be revealed by a private-data logging profile
  (it is redacted before os sees it); formatting moves from read time to call time (a
  `String` is built per call, including debug lines that os would not persist); the
  per-entry static format string is always `%{public}s`, so Console's "message format"
  grouping is gone. None of this affects current call sites' visible output.
- **Forwarding uses the same rendered string**, so `privacy: .private` also keeps a value out
  of Sentry. Only diagnostic installs forward at all.
- Rejected alternatives: a Swift macro emitting both an `os.Logger` call and a forward call
  (needs a swift-syntax macro target in Core, slows every build, still double-formats);
  tailing `OSLogStore` (polling cost, lag, notice+ only, duplicates the export path); adding a
  parallel forward call at 107 sites (duplication, drift).

### 7.3 Forwarder hook

Stored in an `OSAllocatedUnfairLock`; read once per log call (nanoseconds when nil). Levels
`info`, `notice`, `warning`, `error`, `critical`, `fault` are forwarded; `debug`/`trace`
never. `log(level:)` maps `.info → info`, `.default → notice`, `.error → error`,
`.fault → fault`, `.debug → none`. Activity Log entries are forwarded too because `mirror`
goes through the wrapper — they can contain LAN hosts/IPs and AirPlay/display names, which is
what "the app's full activity log" in the disclosure covers.

## 8. PatternSpace wiring

- `PatternSpaceCrashReporting` (wrapper; depends on Core and ReportsKit) gains
  `PatternSpaceLogForwarding.installIfDiagnostic()` (sets the Core forwarder when
  `CrashReporting.activeProfile == .diagnostic`) and the level map
  `info/notice → .info`, `warning → .warning`, `error → .error`, `critical/fault → .fatal`.
- Both `CrashReportingBootstrap.start()` (Release only) call it after `CrashReporting.start`.
  The Settings "Send crash reports" `onChange` calls it after `setEnabled(true)` so a launch
  that started with reporting off also forwards once the SDK starts.
- Metrics: enabled in diagnostic as decided, but no ReportsKit metrics facade and no
  PatternSpace producer exist in this change; adding counters is a follow-up.

## 9. Settings UI and strings

Both platforms keep the "Privacy" section; a second section holds the new toggle.

- Toggle "Share detailed diagnostics", `.disabled(!sendCrashReports)`, accessibility hint
  "Also sends error messages, file names, the app's activity log, and an installation identifier."
- Footer: "Also sends error messages, file and folder names, the app's full activity log,
  and a random identifier for this installation, so problems can be traced across launches.
  Turn on only if you're happy to share this. Takes effect the next time you open PatternSpace."
- The existing footers are reworded to stay true with the new option: "… Unless you turn
  on detailed diagnostics, never includes your files, file names, error text, or an
  identifier for you or your device." (macOS and iOS variants). The old two keys are
  removed from the catalog and five keys added, in en/de/es/fr/it (German Sie-form; Spanish
  usted and Italian tu, matching the existing footers), inserted by hand without re-sorting.

## 10. Disclosures

- **privacy.html:** "does not collect personal data" becomes "by default"; the crash-reports
  item keeps its text with "Unless you turn on detailed diagnostics"; a new list item
  describes "Detailed diagnostics (optional, off by default)": error messages, file and
  folder names, the app's full activity log, a random installation identifier, release-health
  sessions; sent the same way; turning it off discards unsent detailed data at next start.
  No iOS wording. "Last updated" date bumped.
- **App Store privacy label (macOS + iOS)** — must change, because optional collection that
  the user enables once (not per submission) does not meet Apple's "optional to disclose"
  criteria. Declare:
  - Diagnostics → **Crash Data**, **Performance Data**, **Other Diagnostic Data**: **Linked to
    you: Yes**. Apple's label has one answer per data type, not per mode; in detailed mode
    these are collected with a device-level identifier, and Apple treats data tied to a
    device identifier as linked unless de-identified before collection. Default-mode data is
    still unlinked in practice, but the label must state the most identifying case.
  - Identifiers → **Device ID** (the random installation UUID is a device-level ID created by
    the app): **Linked to you: Yes**.
  - All: **Used for tracking: No** (not combined with third-party data, not shared with data
    brokers or ad networks; Sentry is a processor). Purpose: **App Functionality** (Apple's
    examples include minimizing crashes and improving performance).
  - Strict sessions (start/end/status/error count, per-launch ID) are declared under Other
    Diagnostic Data, not Product Interaction: they measure stability, not feature usage.
  - Release checklist line replaced accordingly.
- **Help quickstart (en/de/es/fr/it):** the "never includes" sentence gets "Unless you turn on
  detailed diagnostics"; one short paragraph describes the setting, default off, next-launch
  effect, discard on turning off. HelpHTML regenerated with `MarkdownToHTMLTool`.
- **CHANGELOG** (one unwrapped line per bullet), **AGENTS.md** pin line (still says 0.1.0),
  update note at the top of the 2026-10-12 spec.

## 11. Risks

| Risk | Mitigation |
|---|---|
| PII in diagnostic logs/errors (paths contain the macOS user name; Activity Log has LAN IPs and route names; error text can quote file contents) | Opt-in only, disclosed in the footer and policy; `privacy: .private` respected; no device name/IP/screenshots ever; data deleted on downgrade before send; proxy keeps the user's IP from Sentry |
| Volume/quota | Per-key 10 s, 120/min, 5,000/process caps; 4 KB body cap; batched by the SDK; opt-in population only |
| Profile misselection (diagnostic data sent without consent) | Single path to diagnostic: both stored toggles at start; no override; every event is sanitized with the more private of the started profile and its own collection-time `report.profile` tag (untagged = strict; no timestamps or levels); data collected while opted out carries `report.consent=off` and is dropped; downgrade and opted-out launches purge the cache, purges stay pending until they succeed and block the SDK start (fail closed); applied-profile tag on events for audit; tests per transition |
| Force-quit sessions left open (manual session tracking) | `CachedSessionRecovery` closes them as abnormal via `@_spi(Private)` API in the shipped binary (type-checked; envelope test; exact pin) |
| Unredacted logs on a hot thread | Admission is lock-only; SDK work on a utility queue |
| Session counting distortion (strict users counted per launch) | Documented; Crash Free Users only read for diagnostic installs |
| sentry-cocoa internals (`INSTALLATION` file, synchronous `beforeSendLog`, collection-time scope on stored reports, SPI used for session recovery) change on bump | Exact pin; envelope tests assert each behavior; SPI changes break the build |
| Unified-log fidelity (eager formatting, private values unrecoverable) | Accepted (§7.2); no current call site affected |
| Localization drift (English-as-key change orphans old keys) | Old keys removed by hand; build must not re-add them; `localization-helper` validation |

## 12. Test strategy

ReportsKit (`swift test --no-parallel -Xswiftc -warnings-as-errors`, Swift Testing):

- Unit: preference defaults/persistence (incl. the pending-purge flag); `PrivacyProfile.mostPrivate`;
  `eventProfile` (collection tag only: missing/unknown → strict, level and timestamp ignored);
  `report.consent` never survives the sanitizer; `ErrorDetail` (NSError
  path/description/underlying, Swift associated values, truncation); `ForwardBudget` (repeat
  window, per-minute window reset, process cap, dropped count reported once, pruning) with an
  injected clock; event sanitizer diagnostic keeps/drops per the §5 table on the existing
  `makeCrashEvent` fixture plus planted email/username; log sanitizer per profile (forwarded
  source rejected in strict even when pending; `user.id` kept only in diagnostic; detail and
  category keys stripped in strict; timestamp override); options per profile
  (`enableAutoSessionTracking`, `enableMetrics`, `beforeSendMetric`).
- SDK integration in `SerialSuite` (real envelopes through `RecordingURLProtocol`, waits via
  `SDKHarness.flush(until:)`): `activeProfile` selection (both on / detailed only / reporting
  off); strict session `did` ≠ planted `INSTALLATION` and is a UUID; diagnostic session
  `did` == planted value and event `user.id` == it; diagnostic handled error carries the path
  in `exception.value` with unchanged `report.error`/fingerprint and no computer-name needle;
  strict handled error unchanged (existing tests); replayed events (captured without the
  current scope, as the SDK does) — strict-tagged fatal event, strict-tagged event with a
  future timestamp, strict-tagged error-level hang, and an untagged event — stay redacted and
  are sent tagged `strict` under diagnostic, while a diagnostic-tagged previous-launch event
  keeps its detail; a strict-tagged live event keeps its tag under the diagnostic scope;
  `initialScope` carries `report.profile`; events tagged `report.consent=off` at collection
  are dropped after re-enable and the marker is set/cleared on the scope and never sent;
  force-quit cached session closed as `abnormal`; downgrade deletes the queued envelope;
  failed purges (downgrade, and an opted-out launch followed by re-enable with diagnostics
  selected) keep the SDK off and upload nothing until a retry succeeds; forwarded log delivered
  with category/level/`user.id` in diagnostic; `forwardLog` sends nothing in strict; forwarded
  logs blocked on the wire after opt-out; existing strict suites unchanged except the session
  assertion in `noUserIdentifierAndNoSessionsAcrossStarts`, which moves to the new session tests.

PatternSpace:

- Core: interpolation rendering/privacy defaults; autoclosure not evaluated when redacted;
  forwarder receives info+ with category and rendered text, not debug; `log(level:)` mapping;
  nil forwarder; reader test sees `<private>` in `composedMessage` for a private argument;
  existing `PatternSpaceLogTests`/`DiagnosticsReportTests` unchanged.
- Wrapper: level map; `installIfDiagnostic` leaves no forwarder when the SDK isn't started.
- Both apps build Debug + Release warning-free (proves the 107 call sites compile unchanged);
  pre-tag gate.
- Manual (owner/TestFlight): Settings toggles (greyed state, VoiceOver hint, footers in a
  non-English locale); diagnostic build shows sessions with a stable `did`, forwarded logs
  with `report.category`, error text in handled errors; strict shows sessions with a
  changing `did` per launch and no logs except `CrashReporting.log`.

## 13. Out of scope

Metrics producers; per-category forwarding filters; a "send detailed report now" button;
Android/web; changing the strict `CrashReporting.log` contract; `PrivacyInfo.xcprivacy`
(still absent; Sentry ships its own manifest).

## Appendix — other verified sentry-cocoa 9.24.0 facts used

- `enableAutoSessionTracking` default `true` — `Swift/Options.swift:217`;
  `sessionTrackingIntervalMillis` 30 s — `:231`.
- `enableMetrics` default `true` — `Swift/Options.swift:730`; `beforeSendMetric:
  ((SentryMetric) -> SentryMetric?)?` — `:734`. Metrics are produced only by
  `SentrySDK.metrics` (`Swift/Helper/SentrySDK.swift:102`); `SentryMetricsIntegration.addMetric`
  applies scope attributes (incl. installation `user.id`) then `beforeSendMetric` —
  `Swift/Integrations/Metrics/SentryMetricsIntegration.swift:44-78`. Envelope item type
  `trace_metric` — `Swift/Helper/SentryEnvelopeItemType.swift`.
- Logs: `enableLogs`/`beforeSendLog` — `Swift/Options.swift:142,146`; capture path
  synchronous to `beforeSendLog` — `Sentry/SentryClient.m:1163-1192`; `SentryLog.timestamp`
  mutable — `Swift/Protocol/SentryLog.swift:10`; `SentryAttribute(string:)` —
  `Swift/Protocol/SentryAttribute.swift:33`.
- Event user: `setUserIdIfNoUserSet` sets `user.id` = installation ID when no user —
  `Sentry/SentryClient.m:979-992`, called from `prepareEvent` at `:814`, before `beforeSend` at
  `:848`. `SentryUser.userId` is nullable — `Sentry/Public/SentryUser.h:20`.
- `sendDefaultPii` gates the default log user id only under `SDK_V10`, which the SwiftPM
  product does not set — `Sentry/SentryClient.m:140-149`, `TelemetryScopeApplier.swift:136-140`.
