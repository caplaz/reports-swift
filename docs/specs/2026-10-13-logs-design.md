# Structured logs (0.2.0) — design

## Goals

- Let apps send **warning/error** structured logs for failures that are not worth an event
  (degraded paths, retries, fallbacks) through Sentry Logs.
- Keep every existing privacy guarantee: no user content, no stable identifier, opt-out
  enforced at the transport.
- Additive, non-breaking API.

## API

```swift
extension CrashReporting {
    public enum LogLevel: Sendable { case warning, error }
    /// Message is a compile-time constant: never user data.
    public static func log(_ level: LogLevel, _ message: StaticString, operation: Operation)
    /// Body is "<operation> <describeError(error)>" — never the error's own text.
    public static func log(_ level: LogLevel, _ error: any Error, operation: Operation)
}
```

- Message variant: body = the static message; attributes `report.op`, `report.source`.
- Error variant: body = `"<op> <describeError(error)>"`; attributes `report.op`,
  `report.error` (= `describeError(error)`), `report.source`.
- No-op before `start`, while consent is off, when the SDK is not running, or when
  `configuration.logsEnabled == false`.
- `CrashReportingConfiguration.logsEnabled: Bool` (default `true`, in `init` and
  `standard(...)`); `options.enableLogs = configuration.logsEnabled`.

## Sanitization (`beforeSendLog`)

1. Gate closed → `nil`.
2. The log must carry `report.source = "reportskit"` **and** match the log ReportsKit is
   emitting on this thread right now. `CrashReporting.log` stores the expected log
   (level, body, attributes) in a thread-local slot, calls `SentrySDK.logger`, and clears the
   slot; the SDK runs `beforeSendLog` synchronously on the calling thread (see facts). Any
   other log — from `SentrySDK.logger` directly, an integration, or a forged marker — is
   dropped.
3. The kept log is rebuilt: level and body are set from the expected log; attributes are
   replaced by our own attributes plus the allowlisted SDK attributes below. `timestamp`,
   `trace_id` (random per-process propagation id) and `span_id` are kept.

SDK attribute allowlist: `sentry.release`, `sentry.environment`, `sentry.sdk.name`,
`sentry.sdk.version`, `os.name`, `os.version`, `device.brand` (constant `"Apple"`),
`device.model`, `device.family`.

Stripped (non-exhaustive, everything else is stripped): `user.id` (the SDK adds the cached
installation ID), `user.name`, `user.email`, `sentry.replay_id`,
`sentry._internal.replay_is_buffering`, `sentry.message.template`,
`sentry.message.parameter.*`, every scope attribute.

Implemented as `CrashReportSanitizer.sanitize(log:expected:)` (pure, unit tested).

## Consent

- Logs are sent by the same HTTP transport as events, i.e. through `options.urlSession` →
  `ConsentURLProtocol`, so opt-out blocks (and cancels) them on the wire, including logs
  already buffered by the SDK.
- `beforeSendLog` also returns `nil` while the gate is closed, and `log` returns early.

## Volume

- Only `.warning`/`.error` exist.
- Throttle: at most one log per `(level, operation, body)` per 60 s per process
  (`LogThrottle`, lock-protected, injectable monotonic clock; stale keys pruned).
- The SDK batches logs (≤100 per envelope, 5 s timer), so bursts do not become one request
  per log.

## Tests

- Unit: sanitizer allowlist; rejects missing marker, missing/mismatched expected log;
  error-variant body uses `describeError`; throttle with injected clock; configuration
  default; options mapping (`enableLogs`).
- SDK integration (SerialSuite, real envelopes via `RecordingURLProtocol`,
  `SDKHarness.flush(until:)`): error log → `log` item with only allowlisted attributes and no
  planted path/user/device-name strings; direct `SentrySDK.logger` log dropped; opt-out →
  nothing on the wire; `beforeSendLog` returns `nil` with the gate closed; `logsEnabled =
  false` → `enableLogs == false` and nothing sent.

## Verified sentry-cocoa 9.24.0 facts

Paths relative to `.build/checkouts/sentry-cocoa/Sources`.

- `Options.enableLogs` defaults to `false` — `Swift/Options.swift:142`;
  `Options.beforeSendLog: ((SentryLog) -> SentryLog?)?` — `Swift/Options.swift:146`.
- `SentryLog` is a final class with mutable `timestamp`, `traceId`, `spanId`, `level`,
  `body`, `attributes`, `severityNumber` — `Swift/Protocol/SentryLog.swift:10-22`;
  `setAttribute(_:forKey:)` — `:83`. Levels `trace…fatal` (`warn`, not `warning`) —
  `Swift/Protocol/SentryLogLevel.swift:7-19`.
- `SentrySDK.logger` (`Swift/Helper/SentrySDK.swift:49`) returns the hub's `SentryLogger`
  (`Sentry/SentryHub.m:77`). `warn/error(_ body: String, attributes:)` build a `SentryLog`
  with only the given attributes; `sentry.message.template`/`parameter.N` are added only for
  interpolated `SentryLogMessage` calls — `Swift/Tools/SentryLogger.swift:133-157,183-207`.
- Capture path is synchronous up to `beforeSendLog`: `SentryHub captureLog:`
  (`Sentry/SentryHub.m:910`, adds `sentry.replay_id` when replay is active, `:916-931`) →
  `SentryClient _swiftCaptureLog:withScope:` (`Sentry/SentryClient.m:1163`): drops when
  disabled or `enableLogs == NO` (`:1170`), applies scope (`:1179`), calls `beforeSendLog`
  (`:1183`), then `telemetryProcessor addLog:` (`:1191`).
- Scope enrichment (`Swift/Tools/TelemetryScopeApplier/TelemetryScopeApplier.swift`):
  `sentry.sdk.name/version`, `sentry.environment` (options value at client init, not the
  scope's), `sentry.release` (`:62-69`); `os.name/version` (`:71-81`); `device.brand`
  (`"Apple"`), `device.model`, `device.family` (`:83-96`); `user.id/name/email` from the scope
  user (`:98-108`); replay id (`:110-119`); all scope attributes (`:121-126`); and, when no
  user is set, **`user.id` = the cached installation ID** (`:128-146`; the
  `shouldAddDefaultUserId`/`sendDefaultPii` guard is compiled only under `SDK_V10`, which the
  SwiftPM `Sentry` product does not set). Also sets `traceId` from the propagation context
  and `spanId` from the active span (`:58-59`).
- Batching: `DefaultTelemetryBuffer` with `flushTimeout: 5`, `maxItemCount: 100`, 1 MB —
  `Swift/Tools/TelemetryProcessor/TelemetryProcessor.swift:96-109`. `add` encodes
  asynchronously on `io.sentry.log-batcher` (`Swift/Tools/TelemetryBuffer/TelemetryBuffer.swift:61-65`);
  `capture()` drains synchronously on that queue (`:76-83`); also forwarded on
  `willResignActive`/`willTerminate`
  (`Swift/Tools/TelemetryBuffer/DefaultTelemetryBufferDataForwardingTriggers.swift:31-72`).
  `SentryClient flush:` forwards buffered logs before flushing the transport
  (`Sentry/SentryClient.m:673-681`), so `SentrySDK.flush` makes delivery deterministic
  (modulo the known transport lost-wakeup, handled by `SDKHarness.flush(until:)`).
- Envelope: one item of type `"log"` (`Swift/Helper/SentryEnvelopeItemType.swift:17`),
  content type `application/vnd.sentry.items.log+json`
  (`Swift/Tools/TelemetryProcessor/TelemetryScheduler.swift:21,36-45`), sent through
  `SentryDefaultTelemetryProcessorTransport` → `SentryTransportAdapter sendEnvelope:`
  (`Sentry/SentryDefaultTelemetryProcessorTransport.m:26-29`), i.e. the HTTP transport whose
  session is `options.urlSession` (`Sentry/SentryTransportFactory.m:25,73-77`).
- No auto-forwarding in the core SDK: the only producers of `SentryLog` are `SentryLogger`
  and direct `captureLog`. OSLog/SwiftLog/CocoaLumberjack/SwiftyBeaver/Pulse bridges live in
  `3rd-party-integrations/` as separate products ReportsKit does not depend on; the SDK's own
  diagnostic logger (`SentrySDKLog`) does not emit structured logs.
- Unrelated but noted: `enableMetrics` defaults to `true` (`Swift/Options.swift:730`);
  metrics are produced only by explicit `SentrySDK.metrics` calls.
