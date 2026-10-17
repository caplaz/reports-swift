# Application metrics (ReportsKit 0.3.0-beta.2 + PatternSpace) — design

Date: 2026-10-17
Status: draft for owner review (decisions 1–2 from the owner; open questions in §12)
Repos: `caplaz/reports-swift` (module `ReportsKit`, branch `feature/metrics` stacked on
`feature/privacy-profiles`, today `0.3.0-beta.1`) and PatternSpace (`main`).
Plan: `docs/superpowers/plans/2026-10-17-metrics.md` (PatternSpace repo).
Builds on: `2026-10-16-privacy-profiles-design.md` (profiles, consent gate, sanitizer).

## Goal

Real-time, anonymous performance numbers from every install that has "Send crash reports"
on — how long launches, exports, ICC verifications, invertibility analyses and DeckLink starts
take and how they end, how many SDI frames are late or dropped, how often the system warns
about memory — through the same consent gate, proxy and sanitizer as crash reports, without
any identifier, file name, path or free text.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Who sends | Everyone with "Send crash reports" on, **both profiles**; nothing when it is off. Numbers only (counter, distribution, gauge) with an allowlist of low-cardinality attributes declared in source (operation, format, outcome, …). Never file names, paths, free text, user/installation IDs, device name. Full app logs stay opt-in (unchanged). (Owner.) |
| 2 | Latency | Metrics flow while the app runs (SDK batch ≤ 5 s, §2.4), through `options.urlSession` and the consent gate. (Owner.) |
| 3 | API | Typed `CrashReporting.Metric` declarations (name, kind, unit, allowed attribute keys **and values**); `count`, `distribution`, `gauge`, `duration(since:)`, `measure { }`, and a lock-only `Tally` for hot paths. Values outside a declared set are sent as `other`; undeclared keys are dropped. |
| 4 | Gate | ReportsKit is the only producer: `beforeSendMetric` lets through only the metric ReportsKit is emitting on that thread (same thread-local pattern as logs), rebuilds its attributes from the declaration plus a fixed SDK allowlist, and drops everything else (direct `SentrySDK.metrics` calls included). |
| 5 | Identity | No `user.id` (installation ID) on metrics in **either** profile. Strict: `trace_id` replaced by a fresh random ID per metric and `span_id` removed (the scope's trace ID is constant for the process, §2.3). Diagnostic: trace/span IDs kept, like logs. |
| 6 | Volume | Per-process budget (60/min, 3,000/process) with a `reportskit.metrics.dropped` counter; hot paths aggregate with `Tally` (one count per 60 s at most). SDK envelope cache raised from 30 to 100 so offline metric batches can't evict queued error reports (§6). |
| 7 | Version | Folded into 0.3.0 (still pre-release): **`0.3.0-beta.2`**. PatternSpace re-pins `exact: "0.3.0-beta.2"`. `CrashReportingConfiguration.metricsEnabled` (default `true`) mirrors `logsEnabled`. |
| 8 | Labels | Every PatternSpace metric below is **Performance Data** (already declared). Feature-usage counters (**Product Interaction**, a new label category, and a change to the policy's "no analytics or usage tracking") are a separate optional task the owner can drop (§8.3). |

## 1. What changes for users

| | Before (0.3.0-beta.1) | After (0.3.0-beta.2) |
|---|---|---|
| Strict profile | `enableMetrics = false` | metrics on; ReportsKit-declared metrics only, no ID, random trace ID |
| Diagnostic profile | `enableMetrics = true`, gated `beforeSendMetric`, no producer | same metrics as strict; trace/span IDs kept; still no `user.id` |
| Reporting off | nothing | nothing (facade no-op, queue re-check, `beforeSendMetric` gate, transport gate) |
| PatternSpace | no metrics | 9 Performance-Data metrics (§8.2), optional usage counter (§8.3) |

## 2. sentry-cocoa 9.24.0 facts (verified)

Paths relative to `reports-swift/.build/checkouts/sentry-cocoa/Sources`; interface paths
relative to `.build/artifacts/sentry-cocoa/Sentry/Sentry.xcframework/macos-arm64_arm64e_x86_64/Sentry.framework/Versions/A/Modules/Sentry.swiftmodule/`.

### 2.1 API

- `SentrySDK.metrics: any SentryMetricsApiProtocol` — `Swift/Helper/SentrySDK.swift:102`;
  shipped `arm64-apple-macos.swiftinterface:295`.
- `count(key: String, value: UInt, attributes: [String: any SentryAttributeValue])`,
  `distribution(key:value: Double, unit: SentryUnit?, attributes:)`,
  `gauge(key:value: Double, unit: SentryUnit?, attributes:)` —
  `Swift/Integrations/Metrics/SentryMetricsApiProtocol.swift:21,41,61`, defaults (`value = 1`,
  `unit = nil`, `attributes = [:]`) `:78-102`; interface `:840-848`. Counters take no unit.
- `SentryUnit`: `nanosecond … week`, byte units, `ratio`, `percent`, `.generic(String)`;
  `RawRepresentable`, `Equatable` — interface `:615-640`.
- `SentryAttributeValue` is adopted by `String`, `Bool`, `Int`, `Double`, `Float`, `Array`,
  `Set` — interface `:724-757`. Content enum `SentryAttributeContent` (`string`, `boolean`,
  `integer`, `double`, and arrays) — interface `:482-496`.
- `SentryMetric` is a public struct with mutable `timestamp`, `name`, `traceId`, `spanId`,
  `value` (`SentryMetricValue.counter(UInt) | .gauge(Double) | .distribution(Double)`), `unit`,
  `attributes` — `Swift/Protocol/SentryMetric.swift:4-83`, `SentryMetricValue.swift:25-34`;
  interface `:854-865`. Its initializer is `@_spi(Private)` only (`SentryMetric.swift:68`;
  `arm64-apple-macos.private.swiftinterface:2068`), so unit tests build fixtures with
  `@_spi(Private) import Sentry` (precedent: `Sources/ReportsKit/CachedSessionRecovery.swift:6`).
- `SentryId()` is public (used in `Tests/ReportsKitTests/SerialSuite+Profiles.swift:799`).

### 2.2 Options and callback

- `enableMetrics: Bool = true` (**default on**) — `Swift/Options.swift:730`;
  `beforeSendMetric: ((SentryMetric) -> SentryMetric?)?` — `:734`; interface `:239-240`.
- The integration exists only when `enableMetrics` (`SentryMetricsIntegration.swift:15`);
  otherwise `SentrySDK.metrics.*` logs a warning and returns (`SentryMetricsApi.swift:46-49`).
  Before `start` it also returns (`:42-45`).
- **Capture is synchronous on the caller's thread up to `beforeSendMetric`:** the API builds
  the metric (`SentryMetricsApi.swift:65-77`; timestamp = now, `traceId` = active span's or
  the scope's propagation trace ID) and calls `integration.addMetric` directly, which applies
  the scope (`SentryMetricsIntegration.swift:62`), then calls `beforeSendMetric` (`:64-75`),
  then `client.captureMetric` → `processor.add(metric:)` (`:77,89-100`). Only buffering is
  asynchronous (`TelemetryBuffer.swift:61-65`). So a thread-local "pending metric" is visible
  inside `beforeSendMetric`, exactly like `PendingLog`.
- **Nothing bypasses `beforeSendMetric`:** there is no other producer of `SentryMetric`
  (`SentryMetricsApi` is the only caller of `addMetric`), and its return value replaces the
  metric wholesale (`:74`), so the callback can rewrite attributes, `traceId`, `spanId`,
  `timestamp`. A `nil` return calls `recordDroppedTraceMetric` (`:71`,
  `Sentry/SentryClient.m:1204-1232`), which ends in `recordLostEvent` — a no-op with
  `sendClientReports = false` (`Sentry/SentryHttpTransport.m:150-154`; ReportsKit sets it).

### 2.3 Default attributes (same applier as logs)

`addMetric` runs `scope.addAttributesToItem` with `SentryDefaultScopeApplyingMetadata` built
from options (`SentryMetricsIntegration.swift:22-27`) — the same `TelemetryScopeApplier`
that logs use (`Swift/Tools/TelemetryScopeApplier/TelemetryScopeApplier.swift:29-60`):

| Attribute | Source | Line | ReportsKit |
|---|---|---|---|
| `sentry.sdk.name`, `sentry.sdk.version`, `sentry.environment` (from `Options.environment` at start, never re-read), `sentry.release` | metadata | `:62-69` | keep; environment overridden with the resolved name (as logs, 0.2.2) |
| `os.name`, `os.version` | scope `os` context | `:71-81` | keep |
| `device.brand` ("Apple"), `device.model`, `device.family` | scope `device` context | `:83-96` | keep |
| `user.id`, `user.name`, `user.email` | scope user | `:98-108` | **drop** |
| `sentry.replay_id` | scope (iOS/tvOS UIKit only) | `:110-119` | drop |
| any scope attribute (`Scope.setAttribute`) | scope | `:121-126` | drop |
| `user.id` = installation ID when no user set | `SentryInstallation.cachedId` | `:128-146`; `TelemetryScopeMetadata.swift:32-34` | **drop** — the `shouldAddDefaultUserId` (`sendDefaultPii`) guard exists only under `SDK_V10` (`:136-140`), which the SwiftPM binary doesn't set, so it is added whenever the ID is cached (it is, once sessions run) |
| top-level `trace_id`, `span_id` | active span or scope propagation context | `:58-59` | strict: random per metric, `span_id` removed; diagnostic: keep |

The scope's propagation context is created once with the scope (`Sentry/SentryScope.m:67`)
and replaced only by `setPropagationContextWithTraceId` (`:181-185`, hybrid-SDK API), so
without an active span every metric of a process shares one `trace_id` — a per-launch
linkage key. Strict therefore randomizes it (decision 5). (Events already carry the same
value in `contexts.trace.trace_id` and logs in `trace_id`; that existing within-launch linkage
is unchanged and noted in §11.)

### 2.4 Batching, envelope, transport

- Metrics buffer: flush 5 s after the first item enters an empty buffer, or at 100 items, or
  at 1 MB; serial queue `io.sentry.metric-batcher` —
  `Swift/Tools/TelemetryProcessor/TelemetryProcessor.swift:110-135`,
  `TelemetryBuffer/TelemetryBuffer.swift:89-117`. Also flushed on `willResignActive` /
  `willTerminate` (macOS and iOS) — `DefaultTelemetryBufferDataForwardingTriggers.swift:37-78`,
  and by `SentrySDK.flush` (`Sentry/SentryClient.m:673-682`).
- Encoded at buffering time (`TelemetryBuffer.swift:89-93`); payload `{"items":[…]}`
  (`InMemoryInternalTelemetryBuffer.swift:28-30`).
- Envelope: one item, type `trace_metric` (`Swift/Helper/SentryEnvelopeItemType.swift:18`),
  content type `application/vnd.sentry.items.trace-metric+json`, header
  `SentryEnvelopeHeader.empty()` (no event ID or trace context; SDK info only) —
  `TelemetryProcessor/TelemetryScheduler.swift:22,36-50`, `SentryEnvelopeHeader.swift:21-22,46-48`.
  Rate-limit data categories `trace_metric` / `trace_metric_byte` (`Swift/Networking/SentryDataCategory.swift:25-27,49-50`).
- Transport: `SentryDefaultTelemetryProcessorTransport` → `SentryTransportAdapter` →
  `SentryHttpTransport` (`Sentry/SentryClient.m:135-138`,
  `Sentry/SentryDefaultTelemetryProcessorTransport.m:26-29`), the same path as events and logs:
  stored to the envelope cache, then sent with the request manager built on
  `options.urlSession` (`SentryHttpTransport.m:111-134`). So metric uploads pass
  `ConsentURLProtocol` and the proxy like everything else.
- Cache cap: `maxCacheItems` default 30 (`Swift/Options.swift:130`); on overflow the
  **oldest** envelopes are deleted, whatever they contain (`Swift/Helper/SentryFileManager.swift:280-316`).

## 3. ReportsKit API (0.3.0-beta.2)

```swift
extension CrashReporting.Metric {
    static let exportDuration = Self(
        "export.duration", kind: .distribution, unit: .millisecond,
        attributes: ["format": ["cube", "3dl"], "outcome": Self.outcomes])
}

CrashReporting.count(.memoryWarning, attributes: ["level": "critical"])
CrashReporting.distribution(.queueDepth, 12)
CrashReporting.gauge(.residentMemory, 512, …)
CrashReporting.duration(.exportDuration, since: start, attributes: ["format": "cube", "outcome": "success"])
let data = try await CrashReporting.measure(.exportDuration, attributes: ["format": "cube"]) {
    try await exporter.run()          // outcome added: success / cancelled / failure
}
let late = CrashReporting.Tally(.framesLate, attributes: ["mode": "hd1080p25"])
late.add()                            // hot path: one lock, no SDK work
late.flush()                          // at session end
```

- `Metric(_ name: StaticString, kind:, unit: = .none, attributes: [String: Set<String>] = [:])`.
  Name and keys `^[a-z][a-z0-9_.]{0,63}$`; values `^[A-Za-z0-9_.-]{1,64}$`; ≤ 4 keys; ≤ 64
  values per key; keys must not start with `sentry.`, `user.`, `os.`, `device.`, `report.`;
  counters have no unit. Violations trap at the first use of the declaration (a programming
  error in a `static let`), so a test that touches every declaration proves them.
- `Metric.Unit`: `none`, `millisecond`, `second`, `byte`, `percent`, `ratio`.
- `Metric.outcomeKey = "outcome"`, `Metric.outcomes = ["success", "failure", "cancelled"]`,
  `Metric.otherValue = "other"`.
- Recording calls are callable from **any thread** (unlike `start`/`setEnabled`), cheap on the
  caller: admission (configuration + gate + SDK check + budget, all lock-only), then the SDK
  call runs on ReportsKit's serial utility queue `io.caplaz.ReportsKit.metrics`.
- A kind mismatch (`count` on a distribution) is an `assertionFailure` in Debug and a no-op in
  Release.
- `duration` converts `ContinuousClock` elapsed time into the metric's unit (`millisecond` or
  `second`); `measure` exists in sync and async forms and adds `outcome`.
- `Tally(_ metric:, attributes:, interval: 60)`: `add(_ n: UInt = 1)` accumulates under a lock;
  the first `add` after `interval` has elapsed since the window opened records one `count`
  with the sum; `flush()` records what is pending. Counter metrics only.
- `CrashReportingConfiguration.metricsEnabled: Bool = true` → `options.enableMetrics`.

## 4. Sanitizer and gate (`beforeSendMetric`)

Installed in both profiles:

1. `ConsentGate.shared.isEnabled` else drop.
2. `PendingMetric.current` (thread-local, set only around ReportsKit's own SDK call) must
   exist and match `name`, `value` and `unit`, else drop — this drops direct
   `SentrySDK.metrics` calls from the app or any other library.
3. Attributes rebuilt: SDK keys ∩ `{sentry.release, sentry.environment, sentry.sdk.name,
   sentry.sdk.version, os.name, os.version, device.brand, device.model, device.family}` (the
   strict log allowlist; never `user.*`, `sentry.replay_id`, scope attributes) + the
   declaration-filtered app attributes (as strings) + `sentry.environment` = resolved
   environment when known.
4. `timestamp` = admission time (the SDK's is queue time).
5. Profile = `mostPrivate(started, currentSettingProfile())`: strict → `traceId = SentryId()`,
   `spanId = nil`; diagnostic → unchanged.

### 4.1 Consent and opt-out

| Situation | Result |
|---|---|
| Recorded while reporting is off (any profile) | Never captured: facade no-op. |
| Admitted just before opt-out, still on the ReportsKit queue | Dropped: the queue re-checks the gate before calling the SDK. |
| Inside the SDK call when the gate closes | `beforeSendMetric` reads the live gate after scope application on the same thread; whichever happens first wins — a metric that passed it was collected with consent. |
| Captured before opt-out, in the 5 s buffer or on disk | Blocked on the wire while off (transport gate, as for logs: `optOutBlocksBufferedLogsOnTheWire`); deleted at the next launch if reporting is still off; **delivered if reporting is turned back on in the same process** (existing rule for everything collected with consent; see §12 Q1). |

**No consent marker for metrics.** The event marker (`report.consent=off` scope tag) exists
because events can be *collected* while off and *processed* later (crash/hang replay). Metrics
have no deferred path: collection, scope application and `beforeSendMetric` run in one
synchronous call on the recording thread (§2.2), so the live gate is authoritative; a scope
marker would be read *earlier* than the gate check and add nothing. Scope tags are not metric
attributes anyway (`addScopeAttributes` reads scope *attributes*, `:121-126`).

**Detailed diagnostics turned off in-process:** metrics continue (both profiles send them);
from that moment the strict rules apply (random trace ID).

**Reporting off at launch:** the SDK is not started; `canRecordMetric()` is false.

## 5. Provenance

Metrics carry no `report.profile` tag. The applied profile is decided at capture time from
the started profile and the current setting (§4 step 5); there are no stored metrics from
an earlier launch to re-evaluate except envelopes already sanitized at capture (and a strict
↔ diagnostic change at launch purges or keeps the cache exactly as for events).

## 6. Volume and quota

- Sentry free plan: 5 GB of metrics per month (owner). A serialized metric is ≈ 0.6–0.8 KB
  (9 SDK attributes + ≤ 4 own + fields); estimate 0.7 KB.
- `MetricBudget`: 60 metrics per 60 s window, 3,000 per process; the next admitted metric is
  followed by `reportskit.metrics.dropped` (counter, value = number dropped). Worst case per
  process ≈ 2.1 MB.
- Hot paths use `Tally` (DeckLink frames: ≤ 2 counts per minute while frames are late).
- Typical macOS session (estimate): launch 1, exports 2–20 × 2, verify/analysis 5–60, DeckLink
  ≤ 2/min while problems occur → ~50–200 metrics ≈ 35–140 KB. 5 GB ≈ 36,000 heavy sessions or
  ~150,000 typical ones per month. Revisit after a week of TestFlight data (Sentry Stats).
- Request rate: ≤ 1 metric envelope per 5 s per process → ≤ 12/min, under the proxy's per-IP
  limit (60 requests / 60 s; a denial backs off all categories for 60 s, so the budget also
  protects crash delivery).
- `maxCacheItems` 30 → 100: an offline Mac recording metrics adds one envelope per 5 s of
  activity; with 30 slots, ~2.5 minutes of offline activity would evict queued handled-error,
  log and session envelopes (§2.4). 100 envelopes ≈ 8 minutes of continuous worst-case activity;
  the budget keeps typical sessions far below. (SentryCrash reports are stored by the crash
  reporter and converted at the next launch, so crashes are not at risk.)
- Kill switch: none remote in this design (§12 Q6).

## 7. README / guarantees changes (reports-swift)

- New usage section "7. Record metrics (optional)".
- Privacy profiles table: Metrics row → "ReportsKit-declared only; no ID; random trace ID |
  same; trace/span IDs kept; no `user.id`".
- "What is not sent": replace the "no metrics producer" sentences.
- CHANGELOG `## 0.3.0-beta.2`.

## 8. PatternSpace instrumentation

### 8.1 Where code lives

- `PatternSpaceCore` keeps no ReportsKit dependency. Shared declarations and helpers
  (launch timing, memory pressure, grid buckets) go in `PatternSpaceCrashReporting`
  (`PatternSpaceMetrics.swift`); macOS-only declarations go in the app
  (`Apps/macOS/Sources/Platform/PatternSpaceMetrics+macOS.swift`) where `LUTFormatID`,
  `SDIVideoMode` and `SignalTransfer` are importable, so value sets are derived from
  `allCases` and cannot drift. `SDIVideoMode` and `SignalTransfer` gain `CaseIterable`.
- Every record call is a no-op in Debug/UI-test runs (the SDK is started only in Release:
  `CrashReportingBootstrap.start()` is `#if !DEBUG`).

### 8.2 Performance Data metrics (App Store: Diagnostics → Performance Data, already declared)

| Metric | Type / unit | Attributes (closed sets) | Where |
|---|---|---|---|
| `app.launch.duration` | distribution, ms | — (`os.name` from SDK tells platform) | process start (`sysctl` `kp_proc.p_starttime`) → first main-window `onAppear`; macOS `Apps/macOS/Sources/PatternSpaceApp+MainWindow.swift:21`, iOS `Apps/iOS/Sources/PatternSpaceIOSApp.swift:88`; discarded if ≤ 0 or > 120 s |
| `app.memory.warning` | counter | `level`: warning, critical | `DispatchSource.makeMemoryPressureSource` started by both `CrashReportingBootstrap.start()` |
| `lut.export.prepare.duration` | distribution, ms | `kind`: lut, icc; `format`: `LUTFormatID` raw values + `icc`; `grid`: le17, le33, le65, gt65 (LUT only); `outcome` | `Apps/macOS/Sources/UI/LUTTools/Chain/LUTChainSession+Export.swift` `startPrepare` (`:211-251`), attributes from `prepareExport` (`:135-204`) |
| `lut.export.save.duration` | distribution, ms | `kind`, `format`, `outcome` | same file, `exportPrepared` (`:270-297`) and `exportICC` (`:300-327`) |
| `icc.builder.export.duration` | distribution, ms | `outcome`: success, failure | `Apps/macOS/Sources/UI/ICC/ICCBuilderWindow.swift:353-371` (`data.write`) |
| `icc.verify.duration` | distribution, ms | `source`: preset, imported; `outcome`: ran, refused, not_admitted, failure, cancelled | `Apps/macOS/Sources/UI/ICC/Verify/ICCVerifyModel.swift` `run` (`:135-179`), `cancel` (`:181-186`), `handleCompletion`/`handleFailure` (`:339-352`) |
| `lut.invertibility.duration` | distribution, ms | `grid`; `trigger`: explicit, auto; `outcome`: success, failure, resource_limit, cancelled | `Apps/macOS/Sources/UI/LUTTools/Analysis/LUTInvertibilityStore.swift` `drain` (`:261-305`) |
| `decklink.start.duration` | distribution, ms | `mode`: `SDIVideoMode` raw; `transfer`: `SignalTransfer` raw; `outcome`: success, failure | `Apps/macOS/Sources/Platform/SDI/DeckLinkDeviceProviderAdapter.swift:160-175` (`nativeSession.start()`) |
| `decklink.frames.late` / `decklink.frames.dropped` | counter (via `Tally`, ≤ 1 per 60 s each) | `mode`, `transfer` | same file, completion callback `:188-198`; `flush()` in `stop()` `:223-238` |

The existing throttled `CrashReporting.log(.warning, "frame late"/"frame dropped")` calls
stay for one beta so the two can be compared (§12 Q5).

Note: counts of these durations incidentally show how often operations run. They are
collected and used as performance data (latency and failure rates per format/mode), not to
study feature usage; §12 Q4 asks whether to declare Product Interaction anyway.

### 8.3 Optional — Product Interaction (separate task, owner may drop)

| Metric | Type | Attributes | Where |
|---|---|---|---|
| `feature.window.opened` | counter | `window`: icc_builder, lut_tools, lut_analysis, help | `.onAppear` of each `Window` root in `Apps/macOS/Sources/PatternSpaceApp.swift:183-215` |

Keeping it requires: App Store label **Usage Data → Product Interaction** (Linked to you,
consistent with the current label line; Not used for tracking; App Functionality /
Analytics), privacy.html "there is no analytics or usage tracking" (`web/privacy.html:70-71`)
and "There are no analytics or update checks" (`:130`) rewritten, a footer variant that
mentions "which tools you open", and AGENTS.md. It also overlaps the planned self-hosted
analytics (`caplaz/analytics-swift`, Phase 4) — another reason it is optional.

## 9. Disclosures

- **Settings footers (macOS + iOS)** — the "Send crash reports" footer must say anonymous
  performance measurements are sent. Two keys replaced in place (same sort position: the text
  differs only after "…device model)/Mac model)"):
  - macOS: "Sends anonymous crash and diagnostic data (crash location, app and macOS version,
    Mac model) and anonymous performance measurements, such as how long launches and exports
    take, to help fix problems. Unless you turn on detailed diagnostics, never includes your
    files, file names, error text, or an identifier for you or your device."
  - iOS: "…(crash location, app and iOS version, device model) and anonymous performance
    measurements, such as how long the app takes to launch, to help fix problems. Unless …"
  - de/es/fr/it in the plan (Task B6), German Sie-form, Spanish usted, Italian tu (matching
    the existing footers). The accessibility hint ("Sends anonymous crash and diagnostic data
    to help fix problems.") stays: performance data is diagnostic data.
- **privacy.html:** the crash-reports item replaces "occasionally sends anonymous performance
  timings, for a small sample of sessions" with a description of continuous anonymous
  performance measurements (numbers only, examples, what they are tagged with, same with or
  without detailed diagnostics) plus the existing sampled timings; "Last updated" bumped.
- **Help quickstart (5 locales):** same change to the crash-reports paragraph; HelpHTML
  regenerated with `MarkdownToHTMLTool`.
- **Release checklist** (`docs/ci/release-checklist.md:92`): append that Performance Data
  includes Sentry metrics sent by everyone with crash reports on, without an identifier.
- **CHANGELOG** (`[Unreleased]`, one unwrapped line per bullet), **AGENTS.md** pin + network
  lines.

## 10. Tests

ReportsKit (`swift test --no-parallel -Xswiftc -warnings-as-errors`, Swift Testing, every
command under `timeout`):

- Unit: `Metric` validation helpers, filtering (undeclared key dropped, undeclared value →
  `other`, ≤ 4 keys), unit mapping; `MetricBudget` (window, process cap, dropped count once,
  injected clock); `Tally` (sum, window, flush, saturation, injected clock and emit seam);
  metric sanitizer on `@_spi(Private)` fixtures (strict drops `user.id`/`user.name`/scope
  attributes/replay ID, keeps the SDK allowlist, randomizes `traceId`, clears `spanId`;
  diagnostic keeps trace/span but still no `user.id`; mismatched name/value/unit or no
  pending metric → `nil`; environment and timestamp overrides); options per profile
  (`enableMetrics` follows `metricsEnabled` in both profiles, `beforeSendMetric` installed in
  both, `maxCacheItems == 100`).
- SDK envelopes in `SerialSuite` via `RecordingURLProtocol` and `SDKHarness.flush(until:)`:
  strict `trace_metric` item has only allowlisted attributes, no `user.*`, no planted
  installation ID or scope attribute, no needles, and two metrics have different `trace_id`s;
  diagnostic metrics share the `trace_id` and have no `user.id`; direct `SentrySDK.metrics`
  calls are dropped; metrics recorded while opted out never arrive (also after re-enable);
  a metric admitted to the queue before opt-out (queue suspended) is dropped; buffered metrics
  are blocked on the wire after opt-out; budget overflow produces `reportskit.metrics.dropped`.
- Main-thread rule unchanged for `start`/`setEnabled`; recording tests call from main and
  from a detached task.

PatternSpace: wrapper tests (declarations valid — touching each `static let`; grid buckets;
launch duration from a fixed start; memory-pressure level mapping); macOS
`PatternSpaceTests` (macOS declarations valid; `LUTInvertibilityStore` tests unchanged);
both apps build Debug + Release; pre-tag gate.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Identifier leaks via SDK defaults (`user.id` = installation ID, scope attributes, replay ID) | `beforeSendMetric` rebuilds attributes from an allowlist; envelope tests plant each |
| User data in attribute values | Values must be declared at compile time; anything else is sent as `other` |
| Per-process linkage via `trace_id` | Random per metric in strict. Existing events/logs keep the process trace ID in strict (unchanged, out of scope) |
| Quota exhaustion / proxy back-off | Budget, `Tally`, ≤ 12 envelopes/min; monitor Sentry Stats |
| Offline eviction of queued reports | `maxCacheItems` 100 + budget |
| Hot-path cost (DeckLink completion thread) | `Tally.add` is one lock + add; SDK work on a utility queue |
| sentry-cocoa internals (synchronous `beforeSendMetric`, applier keys) change on bump | Exact pin; envelope tests assert both |
| Label/policy mismatch if feature counters ship | Optional task carries its own disclosure steps |

## 12. Open questions for the owner

1. **Queued metrics after re-enable.** Metrics captured with consent but still queued at
   opt-out are delivered if the user turns reporting back on in the same process (same rule
   as events/logs). Acceptable, or should metric envelopes be deleted at opt-out (needs
   ReportsKit to scan the SDK's envelope directory; racy with the transport)?
2. **Diagnostic identity.** Proposed: no `user.id` on metrics in either profile (decision 1),
   trace/span IDs kept in diagnostic. Alternatives: random trace ID in diagnostic too, or keep
   `user.id` in diagnostic (as logs do).
3. **Cache size** 30 → 100 envelopes (ReportsKit-wide, all apps). OK?
4. **Product Interaction:** ship `feature.window.opened` (new label category + policy rewrite)
   or drop it? And should the duration metrics' implicit counts be declared as Product
   Interaction anyway (conservative reading)?
5. **DeckLink logs:** remove the throttled "frame late"/"frame dropped" logs once the tallies
   are verified (next beta)?
6. **Remote kill switch:** add an env flag to `reports-proxy` that strips `trace_metric` items
   (no app update needed to stop metrics) — separate proxy change?
7. **Budget numbers** (60/min, 3,000/process) and the **launch definition** (process start →
   first main window visible, including the iOS splash).
