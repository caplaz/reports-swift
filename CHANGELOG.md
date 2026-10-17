# Changelog

## 0.3.0-beta.2 — 2026-10-16

### Added

- Metrics: `CrashReporting.Metric` declarations (name, kind, unit, allowed attribute keys and values), `CrashReporting.count`, `distribution`, `gauge`, `duration(_:since:attributes:outcome:)`, `measure` (sync and async, adds `outcome`), and `CrashReporting.Tally` for hot paths. Sent in both profiles while reporting is on, from any thread, budgeted (60/min, 3,000/process, overflow reported as `reportskit.metrics.dropped`). `beforeSendMetric` lets through only ReportsKit's own metrics and rebuilds their attributes: declared attributes plus `sentry.release`/`environment`/`sdk.*`, `os.*`, `device.brand/model/family`; never `user.id`; strict gets a random trace ID per metric. `CrashReportingConfiguration.metricsEnabled` (default `true`).

### Changed

- `enableMetrics` follows `metricsEnabled` in both profiles (was diagnostic-only with no producer).
- `Options.maxCacheItems` is 100 (was the SDK default 30) so offline metric batches can't evict queued reports.
- Opt-out deletes metrics still pending (SDK buffer, transport, disk) so they are never delivered, also after an in-process re-enable: revocation cutoff on ReportsKit-issued timestamps, forced buffer flush, envelope sweeps at opt-out, at re-enable (fails closed) and at the next start, and a wire check in `ConsentURLProtocol` that answers pre-cutoff metric batches with 200 without sending them (bound to the revocation epoch and re-checked atomically with gate admission). Metric-ness is decided from the envelope's item header lines (only metric payloads are parsed); an unreadable upload is refused only when it may hold a metric item, so one unreadable non-metric envelope can't block the upload queue. Sweeps fail closed on listing and read errors too, and skip dot-files, `.tmp` files and subdirectories of `envelopes/`. `Tally` ignores adds while reporting is off and discards totals pending at an opt-out; its `add` makes no SDK call (the SDK-started state is cached under ReportsKit's lock).

## 0.3.0-beta.1 — 2026-10-16

### Added

- Privacy profiles: `CrashReporting.PrivacyProfile` (`.strict`, the default, and `.diagnostic`) and `CrashReporting.activeProfile`. The profile is chosen at SDK start from the stored settings: `.diagnostic` only when the stored "Send crash reports" and the new "Share detailed diagnostics" (`CrashReportingPreference.isDetailedDiagnosticsEnabled`, `CrashReporting.setDetailedDiagnosticsEnabled`, default off) are both on, whatever `enabled` the app passes to `start`.
- Turning "Share detailed diagnostics" off applies immediately: the process is `.strict` from then on (events, breadcrumbs and logs sanitized as strict, no `user.id`, `forwardLog` stops, crash reports collected afterwards tagged `strict`), even if it is turned back on; sessions keep their `did` until the next launch and already-queued reports are still delivered. Turning it on applies at the next SDK start.
- `.diagnostic` sends the error's own text and file/URL user info in handled errors (exception value and `report.error.detail` on error logs), keeps exception reasons, frame file names and full image paths, keeps breadcrumb messages, attaches the installation ID as `user.id`, and sends sessions with the installation ID. It also enables the metrics ingestion path behind the consent gate (`beforeSendMetric`); ReportsKit has no metrics producer yet, so nothing is sent either way today. Device name, IP, screenshots and view hierarchy are never sent.
- `CrashReporting.forwardLog(_:category:message:)`: forwards app log lines in `.diagnostic` only, with `report.category`, budgeted (identical line once per 10 s, 120/min, 5,000/process, `report.dropped` count) and emitted off the caller's thread.
- Event tag `report.profile`: set on the scope at every start (so stored crash and hang reports keep the profile they were collected under) and rewritten to the profile actually applied before sending.

### Changed

- Release-health sessions are now on in both profiles. In `.strict`, ReportsKit deletes sentry-cocoa's `INSTALLATION` file before every start, so each launch's sessions carry a new random `did` and no identifier is shared across launches (timing could still correlate adjacent launches) (Crash Free Sessions is accurate; Crash Free Users counts launches).
- Going from `.diagnostic` back to `.strict` deletes everything queued but not yet sent before the SDK starts; events collected by an earlier launch (crashes, hangs, at any level) are sanitized with the more private of their own `report.profile` tag and the current profile, untagged ones as `.strict`.
- Whole-cache deletions (reporting off at launch, or a downgrade) are recorded as pending until they succeed; the SDK does not start while one is pending.
- Release-health sessions follow consent: ReportsKit starts and ends them itself (auto session tracking off) with sentry-cocoa's 30 s background grace period (`Options.sessionTrackingIntervalMillis`: a shorter absence keeps the session, a longer one ends it and starts a new one, termination ends it), closes an earlier launch's unfinished session (as exited at the time the app left the foreground if it died in the background, else abnormal), and turning reporting off ends the session at once, pauses app-hang tracking for the rest of the process and marks the scope `report.consent=off` so nothing collected while off is ever sent.
- Tracing (`tracesSampleRate`) is now gated by consent independently of profile, through `tracesSampler`: a transaction is sampled (the SDK rolls `tracesSampleRate` and reports it as `sample_rate`) only while reporting is on, and `beforeSend` drops one that spans or finishes during an opted-out interval even if it is processed after re-enable. A transaction created with an explicit `sampled` decision skips `tracesSampler` and is therefore dropped (0.2.2 sent it).
- `start`, `setEnabled` and `setDetailedDiagnosticsEnabled` must be called on the main thread and trap otherwise (`dispatchPrecondition`). A `setEnabled` call made from inside a running transition (e.g. a synchronous observer) is applied after it, so overlapping calls end in the last call's state.

## 0.2.2 — 2026-10-16

### Fixed

- Logs sent via `CrashReporting.log` now carry the environment resolved by `CrashReportingConfiguration.environmentResolver` in their `sentry.environment` attribute, matching error/crash events from the same process. sentry-cocoa 9.24.0's log scope applier (`TelemetryScopeApplier.addDefaultAttributes`) sets that attribute from `Options.environment` captured at `start` and never re-reads the scope, so `configureScope { $0.setEnvironment(name) }` — which does reach events — left logs stuck on the startup environment (e.g. `production` instead of `testflight`) once the resolver returned. The facade now stores the resolved name and `beforeSendLog` overrides the attribute with it.

## 0.2.1 — 2026-10-13

### Changed

- `CrashReporting.apply` now explicitly sets `options.enableMetrics = false`: `CrashReporting` never calls the Metrics API, so the ingestion path stays off rather than relying on the SDK's default.

## 0.2.0 — 2026-10-13

### Added

- Privacy-safe structured logs: `CrashReporting.log(_:_:operation:)` with a `StaticString` message or an error (body `"<operation> <describeError(error)>"`), levels `.warning` and `.error` only.
- `CrashReportingConfiguration.logsEnabled` (default `true`, also a parameter of `init` and `standard(...)`), mapped to sentry-cocoa's `Options.enableLogs`.
- `beforeSendLog` sanitizer: drops every log while reporting is off and every log not emitted by `CrashReporting.log`; keeps only `report.op`, `report.error`, `report.source` and the SDK's release, environment, SDK name/version, OS name/version and device brand/model/family attributes. The installation-ID `user.id` the SDK attaches to logs, `user.*`, replay ids, message templates and scope attributes are stripped.
- Per-process throttle: at most one identical log (level, operation, body) per 60 seconds.

Logs use the same consent-gated `URLSession` as events, so opting out also blocks logs already batched by the SDK.

## 0.1.0

- Initial release: `CrashReporting` facade over sentry-cocoa 9.24.0 with allowlist sanitizer, transport-level consent gate and opt-out semantics.
