# Changelog

## 0.2.0 — 2026-10-13

### Added

- Privacy-safe structured logs: `CrashReporting.log(_:_:operation:)` with a `StaticString` message or an error (body `"<operation> <describeError(error)>"`), levels `.warning` and `.error` only.
- `CrashReportingConfiguration.logsEnabled` (default `true`, also a parameter of `init` and `standard(...)`), mapped to sentry-cocoa's `Options.enableLogs`.
- `beforeSendLog` sanitizer: drops every log while reporting is off and every log not emitted by `CrashReporting.log`; keeps only `report.op`, `report.error`, `report.source` and the SDK's release, environment, SDK name/version, OS name/version and device brand/model/family attributes. The installation-ID `user.id` the SDK attaches to logs, `user.*`, replay ids, message templates and scope attributes are stripped.
- Per-process throttle: at most one identical log (level, operation, body) per 60 seconds.

Logs use the same consent-gated `URLSession` as events, so opting out also blocks logs already batched by the SDK.

## 0.1.0

- Initial release: `CrashReporting` facade over sentry-cocoa 9.24.0 with allowlist sanitizer, transport-level consent gate and opt-out semantics.
