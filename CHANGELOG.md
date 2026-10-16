# Changelog

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
