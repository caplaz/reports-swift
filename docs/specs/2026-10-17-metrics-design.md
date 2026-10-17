# Application metrics (ReportsKit 0.3.0-beta.2 + PatternSpace) — design

Date: 2026-10-17
Status: owner decisions recorded 2026-10-16 (Decisions table); no open questions (§12).
Revised 2026-10-16 for review findings: wire verdict bound to admission (§4.2 "Wire check"),
fail-closed sweeps (§4.2 "Sweep"), `Tally` across consent changes (§3, §4.2 "Revocation epoch").
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
| 5 | Identity | No `user.id` (installation ID) on metrics in **either** profile. Strict: `trace_id` replaced by a fresh random ID **per metric** and `span_id` removed (the scope's trace ID is constant for the process, §2.3). Diagnostic: trace/span IDs kept, like logs. (Owner.) |
| 6 | Volume | Per-process budget **60/min, 3,000/process** with a `reportskit.metrics.dropped` counter; hot paths aggregate with `Tally` (one count per 60 s at most). SDK envelope cache raised from 30 to **100** (ReportsKit-wide) so offline metric batches can't evict queued error reports (§6). No remote kill switch. (Owner.) |
| 7 | Version | Folded into 0.3.0 (still pre-release): **`0.3.0-beta.2`**. PatternSpace re-pins `exact: "0.3.0-beta.2"`. `CrashReportingConfiguration.metricsEnabled` (default `true`) mirrors `logsEnabled`. |
| 8 | Labels | Every PatternSpace metric is **Performance Data** (already declared). **No feature-usage metrics**; the privacy policy keeps "there is no analytics or usage tracking". (Owner.) |
| 9 | Opt-out | Metrics recorded before an opt-out and not yet sent are **deleted**, never delivered — also not after reporting is turned back on in the same process (§4.2). (Owner.) |
| 10 | PatternSpace scope | Launch = process start → first main window. The throttled DeckLink "frame late"/"frame dropped" logs stay alongside the new tallies for now. (Owner.) |

## 1. What changes for users

| | Before (0.3.0-beta.1) | After (0.3.0-beta.2) |
|---|---|---|
| Strict profile | `enableMetrics = false` | metrics on; ReportsKit-declared metrics only, no ID, random trace ID |
| Diagnostic profile | `enableMetrics = true`, gated `beforeSendMetric`, no producer | same metrics as strict; trace/span IDs kept; still no `user.id` |
| Reporting off | nothing | nothing (facade no-op, queue re-check, `beforeSendMetric` gate, transport gate); metrics still pending at the opt-out are deleted (§4.2) |
| PatternSpace | no metrics | 9 Performance-Data metrics (§8.2); no feature-usage metrics |

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

### 2.5 Where pending metrics live, and what can reach them (for §4.2)

Paths as in §2; `private interface` = `arm64-apple-macos.private.swiftinterface` next to the
public one; `PrivateSentrySDKOnly.h` is in the framework's public `Headers/`. Items are cited
as §2.5.1–§2.5.6.

1. **SDK metric buffer (in memory).** `add` enqueues the already-sanitized metric on the
   serial queue `io.sentry.metric-batcher` (`TelemetryBuffer.swift:61-65`); it becomes an
   envelope when `performCaptureItems` calls the buffer's `capturedDataCallback`
   (`:125-141`).
   - **No hook at batch time.** The callback is fixed by the factory to
     `scheduler.capture` (`TelemetryProcessor.swift:120-135`), which wraps the batch in a
     one-item envelope and hands it to the transport (`TelemetryScheduler.swift:36-45`).
     `beforeSendMetric` runs only when a metric is added (`SentryMetricsIntegration.swift:64-75`).
     The processor is reachable only through `-[SentryClient getTelemetryProcessor]`, declared
     in `Sentry/include/SentryClient+Private.h:117`, which the binary does not ship (its
     `PrivateHeaders/` lack it). So ReportsKit cannot filter or clear a batch.
   - **It can force the batch out synchronously.** `SentrySDK.flush(timeout:)`
     (`Swift/Helper/SentrySDK.swift:658-660` → `Sentry/SentrySDKInternal.m:571-574` →
     `Sentry/SentryHub.m:882-888` → `Sentry/SentryClient.m:673-682`) first calls
     `forwardTelemetryData` (`:675`), whose `metricsBuffer.capture()` is a `dispatchSync` on the
     batcher queue (`TelemetryProcessor.swift:42-46`, `TelemetryBuffer.swift:76-83`). It runs
     after every `add` already enqueued and returns once the batch was handed to
     `transport.sendEnvelope`. Only then does it wait for the transport (`:681`). Calling it on
     the main thread is supported (`TelemetryBuffer.swift:72-75`). Nothing on the flush path
     needs the main queue.
2. **Transport queue (in memory, briefly).** `SentryHttpTransport.sendEnvelope`
   (via `SentryDefaultTelemetryProcessorTransport.m:26-29`, `SentryTransportAdapter.m:92-96`)
   first drops rate-limited items (`SentryHttpTransport.m:113-118`). It adds no client report
   (`sendClientReports = false`, `:268-270`), then **stores asynchronously** on the private
   serial queue `io.sentry.http-transport` (`:126-135`; queue `SentryTransportFactory.m:87-96`).
   ReportsKit cannot reach that queue. The transport's own `flush` enqueues a
   `sendAllCachedEnvelopes` behind the store (`:207-211`) and waits on a dispatch group
   (`:213`), but any drain that ends (`finishedSending`, `:454-460`) also releases that group.
   Concurrent drains are common (`SDKHarness.flush(until:)` documents the reachability one), so
   a flush that returns is **not** a guarantee that the store ran.
   - If the write fails, the envelope stays in memory (`notStoredEnvelopes`, `:127-132`) and is
     sent first on the next drain (`:314-318`).
3. **Disk.** `<cacheDirectoryPath>/io.sentry/<DSN hash>/envelopes/*.json`. The paths are built
   at `SentryFileManagerHelper.m:145-149` (base), `:166-167` (DSN hash) and `:14,192`
   (`envelopes`). Files are written under `@synchronized` (`:204-220`) with ascending names
   (`:1014-1023`), and the transport sends the oldest first (`SentryHttpTransport.m:323`).
   The envelopes are plain (uncompressed) SDK serializations. Reading:
   `PrivateSentrySDKOnly.envelope(with:)` (`PrivateSentrySDKOnly.h:50` →
   `PrivateSentrySDKOnly.m:42-45` → `SentrySerializationSwift.swift:96`) is the same
   deserializer the transport uses (`SentryHttpTransport.m:331`), and the transport deletes an
   undeserializable file without sending it (`:333-337`). `SentryEnvelope.items`,
   `SentryEnvelopeItem.type()` and `.data`, and `SentryEnvelopeItemTypes.traceMetric` are SPI
   (private interface `:820`, `:1802`, `:1794`, `:129`). A refused send (no HTTP response) keeps
   the file (`SentryHttpTransport.m:407-410`); a 2xx/4xx/5xx response deletes it (`:433-447`).
4. **Metric envelopes are never mixed in 9.24.0.** The scheduler builds one-item `trace_metric`
   envelopes (`TelemetryScheduler.swift:40-42`). Nothing adds items to them later:
   - client reports are off (`SentryHttpTransport.m:268-270`);
   - rate limiting only removes items (`SentryEnvelopeRateLimit.m:29-47`);
   - eviction's session-init migration rewrites only an envelope that already holds a
     `session` item with the same session ID (`SentryMigrateSessionInit.swift:62-77`).
5. **Wire.** Every send is one `POST` of the gzipped envelope through `options.urlSession`
   (`SentryURLRequestFactory.swift:20-38`). `ConsentURLProtocol` already reads the whole
   body before admitting it (`Sources/ReportsKit/ConsentURLProtocol.swift:33-52`). A
   `trace_metric` item's payload is `{"items":[…]}` (`InMemoryInternalTelemetryBuffer.swift:28-30`),
   and each metric's `timestamp` is encoded as seconds since 1970 (`:5-9`,
   `Swift/Protocol/SentryMetric.swift:86-101`).
6. **Envelope SPI for tests.** `SentryEnvelope(header:items:)`, `SentryEnvelopeItem(type:data:contentType:itemCount:)`,
   `SentryEnvelopeHeader.empty()` (private interface `:818`, `:1795`, `:1314`);
   `SentryNSURLRequestBuilder.createEnvelopeRequest(_:url:)` gzips like production
   (`:1646`). `PrivateSentrySDKOnly.capture(_:)`/`store(_:)` (`PrivateSentrySDKOnly.h:43,45`)
   reach the transport's `sendEnvelope` and the synchronous `SentryFileManager.store`
   (`SentryHub.m:762-784`, `SentryClient.m:588-596,646-649`). ReportsKit already uses
   `capture` (`CachedSessionRecovery.swift:35-36`).

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
late.add()                            // hot path: lock-only, no SDK work
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
- `Tally` and consent (decision 9, §4.2 "Revocation epoch"):
  - `add` is a no-op while a metric can't be recorded (`canRecordMetric()` false, or between
    revoke and reopen).
  - The pending total is tagged with the revocation epoch it was counted in. A total from an
    earlier epoch is discarded, never sent, at the next `add` (which also reopens the window)
    or at `flush`.
  - The emission carries the epoch and is admitted only while it is current, under
    `MetricRevocation`'s lock. A flush that took its total before an opt-out and reaches
    admission after the re-enable records nothing.
- `CrashReportingConfiguration.metricsEnabled: Bool = true` → `options.enableMetrics`.

## 4. Sanitizer and gate (`beforeSendMetric`)

Installed in both profiles:

1. `ConsentGate.shared.isEnabled` else drop.
2. `PendingMetric.current` (thread-local, set only around ReportsKit's own SDK call) must
   exist and match `name`, `value` and `unit`, else drop — this drops direct
   `SentrySDK.metrics` calls from the app or any other library. A pending metric admitted
   before the latest opt-out (§4.2) is dropped too.
3. Attributes rebuilt: SDK keys ∩ `{sentry.release, sentry.environment, sentry.sdk.name,
   sentry.sdk.version, os.name, os.version, device.brand, device.model, device.family}` (the
   strict log allowlist; never `user.*`, `sentry.replay_id`, scope attributes) + the
   declaration-filtered app attributes (as strings) + `sentry.environment` = resolved
   environment when known.
4. `timestamp` = admission time (the SDK's is queue time), issued by ReportsKit and strictly
   increasing within the process (§4.2).
5. Profile = `mostPrivate(started, currentSettingProfile())`: strict → `traceId = SentryId()`,
   `spanId = nil`; diagnostic → unchanged.

### 4.1 Consent and opt-out

| Situation | Result |
|---|---|
| Recorded while reporting is off (any profile) | Never captured: facade no-op. |
| Admitted just before opt-out, still on the ReportsKit queue | Dropped: the queue re-checks the gate and the revocation (§4.2) before calling the SDK. |
| Inside the SDK call when the gate closes | `beforeSendMetric` reads the live gate after scope application on the same thread. If it passed first, the metric is in the SDK buffer and is handled like the next row. |
| Captured before opt-out, in the 5 s buffer, the transport queue or on disk | **Deleted, never delivered** — also not after reporting is turned back on in the same process (decision 9, §4.2). |
| Upload whose wire verdict was taken before the opt-out, admitted after the re-enable | Not forwarded: the gate sees the verdict's epoch is stale, the request is decided again against the new cutoff (swallowed) (§4.2 "Wire check"). |
| `Tally` total pending at the opt-out, or adds while off | Discarded, never sent, also when the flush races the re-enable (§3, §4.2 "Revocation epoch"). |

**No consent marker for metrics.** The event marker (`report.consent=off` scope tag) exists
because events can be *collected* while off and *processed* later (crash/hang replay). Metrics
have no deferred path: collection, scope application and `beforeSendMetric` run in one
synchronous call on the recording thread (§2.2), so the live gate is authoritative; a scope
marker would be read *earlier* than the gate check and add nothing. Scope tags are not metric
attributes anyway (`addScopeAttributes` reads scope *attributes*, `:121-126`).

**Detailed diagnostics turned off in-process:** metrics continue (both profiles send them);
from that moment the strict rules apply (random trace ID).

**Reporting off at launch:** the SDK is not started; `canRecordMetric()` is false.

**Other telemetry is unchanged:** queued events, logs and sessions collected with consent are
still delivered after an in-process re-enable (existing rule). Decision 9 applies to
`trace_metric` envelopes only.

### 4.2 Deleting pending metrics at opt-out (decision 9)

**Short answer for the in-memory buffer:** sentry-cocoa 9.24.0 has no hook when a metric
batch is formed or flushed (§2.5.1). ReportsKit can't stop a sanitized metric from becoming
an envelope. What it can do:

- force the buffer into an envelope synchronously at opt-out, while the gate is closed;
- delete that envelope from disk;
- refuse delivery of any metric envelope, wherever it was, through a check made when the
  request is sent.

Only one case falls outside "deleted at opt-out". The forced envelope is written to disk
asynchronously on a queue ReportsKit can't wait on (§2.5.2). If it lands after the opt-out
sweep, it is deleted later by one of three steps below (re-enable sweep, wire check, or
next-launch sweep), and it is **never delivered**.

**Revocation cutoff (`MetricRevocation`).** Each metric's admission timestamp comes from
ReportsKit. It is strictly increasing in the process: at least 1 ms after the previous one,
even if the wall clock steps back. While the clock is behind, timestamps run up to that far
ahead of it. Opt-out sets `cutoff` = the last timestamp issued and stops admission. Re-enable
reopens admission, and every later timestamp is > `cutoff`. So "admitted before the latest
opt-out" is exactly `timestamp ≤ cutoff`. This works without trusting the clock, in both
profiles, and needs no attribute that would be sent to Sentry. Admission and revocation share
one lock, so a racing `record` either gets a timestamp ≤ `cutoff` or no timestamp at all.

**Revocation epoch.** Every `revoke()` also starts a new epoch, even when nothing was issued
yet (no cutoff). The cutoff changes only in `revoke()`. So a decision taken under an epoch that
is still current was taken against the current cutoff, and a decision from an older epoch
must be taken again. Two decisions depend on this:

- the wire verdict, re-checked atomically with gate admission ("Wire check" below);
- `Tally`'s pending totals (§3). `MetricRevocation.admit(epoch:)` issues a timestamp only while
  the given epoch is current, in the same critical section as revocation.

**Opt-out** (`applyConsent(false)`, inside the serialized transition, after the gate,
consent marker, hang and trace steps):

1. Persist `pendingMetricSweep = true` (before deleting anything, like `pendingPurge`).
2. `metricRevocation.revoke()`.
3. `metricQueue.sync {}`. The queue is serial, so every ReportsKit emission queued or
   running finishes before this returns. Those that start now see the closed gate (and the
   revocation) and are dropped. Only ReportsKit emissions pass `beforeSendMetric`
   (decision 4), so afterwards every metric that passed it has been enqueued in the SDK
   buffer (`TelemetryBuffer.swift:61-65`).
4. `SentrySDK.flush(timeout: 1)` if the SDK runs. It forwards the metric (and log) buffers to
   the transport synchronously (§2.5.1). A metric batch sent here is pre-cutoff, so the wire
   check (below) answers it with a synthetic 200 before the closed gate is even consulted, and
   the transport deletes the envelope unsent (`SentryHttpTransport.m:433-447`). Other envelope
   types aren't metrics, so the wire check forwards them to the gate, which is closed: their
   send attempts are refused (no response) and the files stay — logs keep their existing rule.
   Step 5 sweeps any metric envelope this flush didn't reach.
5. Sweep (`deleteMetricEnvelopes`): every file in `io.sentry/*/envelopes/` that deserializes
   to an envelope with a `trace_metric` item is removed with ReportsKit's
   `removeItem`/`remove` (absence counts as success; the result is checked). Most of the time
   the flush in step 4 returns only after its own drain, which is queued behind the forced
   store (§2.5.2), so the forced envelope is already on disk and deleted here. A failed
   sweep leaves the gate closed; nothing else is needed yet, because re-enable sweeps again.

**Sweep (fails closed).** The sweep succeeds only when it inspected every envelope and every
metric envelope is gone. The same rules apply at opt-out, re-enable and launch:

| Situation | Result |
|---|---|
| No `io.sentry` directory, a DSN directory without `envelopes`, a file deleted between listing and reading | Absent: success |
| Listing a directory fails (other than "no such file"), or a DSN entry's `isDirectory` can't be read | Failure |
| An envelope file can't be read (other than "no such file") | Failure: it may hold a metric |
| A file the SDK can't deserialize | Removed. The transport would delete it unsent (`SentryHttpTransport.m:331-337`), and envelopes are written atomically (`SentryFileManagerHelper.m:592-599`), so nothing deliverable is lost |
| A removal fails | Failure |

After a failure the sweep keeps going and deletes what it can. Listing and reading go through
test seams (`listDirectory`, `readFile`), like `removeItem`.

**Re-enable in the same process** (`applyConsent(true)`, SDK running, before the consent
marker is removed and the gate reopens):

1. `SentrySDK.flush(timeout: 1)` with the gate still closed, so a late forced envelope lands.
2. Sweep again. **If the sweep fails (listing, reading or removal): fail closed.** Set
   `pendingPurge`, leave the gate closed, stop. Reporting stays off for this process, and the
   next start purges the whole cache before starting, or doesn't start (existing `startSDK`
   behaviour).
3. `metricRevocation.reopen()`, then the existing steps (marker removed, gate, traces,
   sessions, drain).

**Wire check (backstop, `ConsentURLProtocol`).** It only runs in a process that has opted
out at least once (`cutoff` set); other processes skip it without parsing. For every upload
it gunzips the body and deserializes it with the SDK's own parser. If any `trace_metric`
item holds a metric with `timestamp ≤ cutoff`, or has no readable timestamp, the request is
answered with a **synthetic HTTP 200** and never forwarded. The transport then deletes the
envelope (`SentryHttpTransport.m:433-447`) and moves on to the next one. This catches the
forced envelope even when it landed after both sweeps, is still in `notStoredEnvelopes`
(failed write, §2.5.2), or is sent by a drain started before the flush.

The verdict and the admission are **one decision**. Otherwise a request could get `.forward`
(say, before the first opt-out, with no cutoff), pause, span an opt-out and re-enable, and
then be admitted by the reopened gate. So:

- `checkedVerdict` reads the cutoff and the epoch together and returns the verdict with the
  epoch it was decided under.
- A `.forward` request is admitted only through `ConsentGate.admit(while:)`, which checks
  under the gate's lock that the gate is open **and** that epoch is still current.
- Any opt-out between verdict and admission either finds the gate closed (refused) or, after
  the re-enable, a new epoch (`stale`). A stale request is decided again against the new
  cutoff, at most 3 times, then refused.
- An opt-out that starts after the admission cancels the admitted task, as for every upload.
- `.swallow` and `.refuse` need no epoch check. The cutoff only grows (it is the last issued
  timestamp, strictly increasing), so a metric pre-cutoff under an old epoch is pre-cutoff
  under the current one; a refusal sends nothing.
- Lock order: gate, then revocation; the revocation lock never takes the gate's.

A body that can't be gunzipped or deserialized is **refused** (no response). The file stays
and the transport stops draining for the rest of the process. That is fail-closed without
destroying a possible crash report, and it can't happen with SDK-built bodies (§2.5.5). The
next launch has no cutoff, so the file is sent then. If it was a metric envelope, the launch
sweep deletes it first.

**Next launch** (`prepareCache`, before `SentrySDK.start`, nothing sending):

- If `pendingMetricSweep` is set: sweep, then clear the flag.
- If the sweep fails (listing, reading or removal, see "Sweep" above): keep the flag, set
  `pendingPurge` and fail closed (`startSDK` doesn't start, the gate stays closed). The next
  start (the next launch, or `setEnabled(true)` in this process) purges the whole cache
  before starting. That purge doesn't need to inspect the cache, so it recovers even while
  the cache stays unreadable; otherwise it fails closed again (existing rule).
- A whole-cache purge (`purgeCache`) also clears the flag.

This covers a process that exited between a late store and its send attempt. The flag is
never cleared in-process: a late landing can't be ruled out there. As a result, metric
envelopes still queued at the next launch after an opt-out are deleted even if they were
recorded after the re-enable. That over-deletion is deliberate: they are low-value
performance numbers.

**Mixed envelopes.** The sweep deletes any envelope containing a `trace_metric` item, and
the wire check drops it whole. In 9.24.0 such envelopes always have exactly one item
(§2.5.4), so no other item is ever discarded. A future SDK that batches metrics with other
items would be caught by the envelope-shape test (§10). Until the rule is revisited,
dropping the whole envelope is the fail-closed choice. Rewriting SDK envelope files in place
would mean ReportsKit re-serializing them, a path only the SDK's private migration uses.

**Rejected alternatives.**

- A sentinel envelope sent through `PrivateSentrySDKOnly.capture` as a FIFO barrier on the
  transport queue: the rate limiter drops it under any `all`-category back-off
  (`SentryEnvelopeRateLimit.m:53-58`, `DefaultRateLimits.swift:33-41`), so the barrier would
  time out exactly when the proxy is backing off.
- Calling `getTelemetryProcessor` through the ObjC runtime: the selector is undeclared in the
  shipped headers (§2.5.1), and it would only forward the buffer, which `flush` already does.
- Clearing `notStoredEnvelopes` via KVC: private, unversioned state.

**Cost.** Each opt-out and re-enable blocks the main thread for at most ~1 s (the flush
timeout) plus a directory scan, which is typically a few milliseconds. The wire check
gunzips at most one ≤ 1 MB body per upload, and only after an opt-out.

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
- Kill switch: none (owner decision 6); stopping metrics needs an app update with
  `metricsEnabled: false`.

## 7. README / guarantees changes (reports-swift)

- New usage section "7. Record metrics (optional)".
- Privacy profiles table: Metrics row → "ReportsKit-declared only; no ID; random trace ID |
  same; trace/span IDs kept; no `user.id`".
- "What is not sent": replace the "no metrics producer" sentences.
- Opt-out guarantee: metrics recorded before turning reporting off are deleted and never sent,
  also if it is turned back on in the same process (§4.2).
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
stay for now (decision 10). Removing them is a later, separate change.

Note: the number of recorded durations incidentally shows how often operations run. These
metrics are collected and used only as performance data: latency and failure rates per
format or mode. PatternSpace records no feature-usage metrics (decision 8), so the privacy
policy's "there is no analytics or usage tracking" stays true and the label stays
Performance Data only.

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
  - de/es/fr/it in the plan (Task B7), German Sie-form, Spanish usted, Italian tu (matching
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
  every metric envelope has exactly one item (pins §2.5.4); diagnostic metrics share the
  `trace_id` and have no `user.id`; direct `SentrySDK.metrics` calls are dropped; metrics
  recorded while opted out never arrive (also after re-enable); a metric admitted to the
  queue before opt-out (queue held by a blocked work item, never `suspend()`ed — the opt-out
  barrier syncs on it) is dropped; budget overflow produces `reportskit.metrics.dropped`.
- Deletion at opt-out (§4.2), envelope level:
  - a metric recorded and buffered, then opt-out and re-enable in the same process: no
    `trace_metric` item with it is ever delivered, while a metric recorded after re-enable is;
  - a metric envelope already on disk (network failing) is deleted by the opt-out, a queued
    event envelope is kept and delivered after re-enable, no `trace_metric` is delivered;
  - a pre-cutoff metric envelope that reaches the transport after re-enable (planted with
    `PrivateSentrySDKOnly.capture`) is swallowed on the wire and deleted from disk; the same
    envelope is delivered in a process that never opted out (control);
  - an upload paused (test seam) right after a `.forward` verdict, then opt-out and re-enable,
    then resumed: the gate reports the verdict stale, it is decided again (`.swallow`), answered
    with the synthetic 200 and never forwarded;
  - a removal failure (`removeItem` seam) keeps the gate closed after re-enable and sets
    `pendingPurge`, and the next launch purges and delivers no metric;
  - a metric envelope left on disk by a process that opted out is deleted by the next
    launch's sweep before anything is sent, and the flag is cleared;
  - the next launch's sweep with an injected listing failure, and separately an injected read
    failure: the flag is kept, `pendingPurge` set, the SDK not started, the envelope still on
    disk; then `setEnabled(true)` purges the cache, clears both flags, starts, delivers no
    metric;
  - `Tally` end to end: accumulate, opt out, add while off, re-enable, flush → nothing sent;
    later adds are sent. A total taken before the opt-out and emitted after the re-enable,
    with its old epoch, is not recorded.
- Unit: `MetricRevocation` (strictly increasing timestamps with a clock stepping back; revoke
  closes admission and sets the cutoff; reopen issues timestamps > cutoff; wire verdicts on
  SDK-gzipped bodies: old metric → swallow, new → forward, event → forward, no cutoff →
  forward without parsing, corrupt gzip → refuse; every revoke starts a new epoch,
  `admit(epoch:)` refuses an old one, `checkedVerdict` carries its epoch);
  `ConsentGate.admit(while:)` (closed before validity, stale without building a task, admitted
  tasks still revoked); `deleteMetricEnvelopes` on SDK-serialized files (metric removed, event
  kept, undeserializable file removed, removal failure reported; absent cache and vanished
  file → success; injected listing or read failure → failure, file kept); `Tally` with
  injected consent (adds while off ignored, old-epoch totals discarded at `add` and `flush`,
  emissions tagged with their epoch).
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
| Hot-path cost (DeckLink completion thread) | `Tally.add` is a few uncontended locks (consent check + its own) + add; SDK work on a utility queue |
| sentry-cocoa internals (synchronous `beforeSendMetric`, applier keys, envelope paths, one-item metric envelopes, deserializer SPI) change on bump | Exact pin; envelope and deletion tests assert each; re-verify §2.5 on every bump |
| A pre-opt-out metric envelope is written after both sweeps (async store, §2.5.2) | Wire check swallows it (synthetic 200 → transport deletes it); next-launch sweep |
| Wire verdict taken before an opt-out, admission after the re-enable | Verdict bound to its revocation epoch; gate admission re-checks it under the gate's lock; stale → decided again |
| Deletion fails (permissions, I/O), or the cache can't be listed or an envelope read | Fail closed: gate stays closed after re-enable, `pendingPurge` → whole-cache purge or no start next launch; a failed launch sweep keeps `pendingMetricSweep` and doesn't start |
| `Tally` total spans an opt-out (pending, or flushed concurrently with the re-enable) | No adds while off; totals tagged with the revocation epoch, discarded when it changes; emission admitted only under that epoch |
| Unparseable upload body after an opt-out stalls the transport for the process | Refused, not swallowed (no data destroyed); SDK-built bodies always parse (§2.5.5); next launch sends it |
| Main thread blocked during a consent toggle | ≤ ~1 s flush timeout + directory scan; typically milliseconds |
| Timestamps ahead of the wall clock after it steps back | Bounded by the step-back size; only in that case; Sentry stores the given value |
| Metrics queued at the next launch after an opt-out are deleted, including post-re-enable ones | Deliberate over-deletion (privacy first); low-value data |

## 12. Open questions for the owner

None. The owner answered every earlier question on 2026-10-16:

- deletion at opt-out → decision 9, §4.2;
- identity → decision 5;
- cache size → decision 6;
- no feature-usage metrics → decision 8;
- DeckLink logs → decision 10;
- kill switch → decision 6;
- budget and launch definition → decisions 6 and 10.
