# reports-swift

Privacy-first crash reporting for Apple-platform apps. `ReportsKit` is a thin facade over
[sentry-cocoa](https://github.com/getsentry/sentry-cocoa) that:

- sends **no user content** — every event, breadcrumb, span and log is reduced to an
  allowlist before it is written to disk or sent;
- enforces the user's **opt-out at the transport level**, so nothing leaves the device once
  reporting is turned off — not even reports that were already queued;
- never attaches a **stable identifier** for the user or the device in the default `strict`
  privacy profile. A user can opt in to a `diagnostic` profile that adds error text, file
  names, the app's own log lines and a random installation identifier (see
  [Privacy profiles](#privacy-profiles)).

It is meant to be used with a DSN whose host is a reverse proxy you control (for example
[`reports.caplaz.com`](https://github.com/caplaz/reports-proxy), a Cloudflare Worker), so the
app never talks to `*.sentry.io` and Sentry never sees the user's IP address.

Requires macOS 15.4+ / iOS 18.4+, Swift 5.10+.

## Installation

```swift
.package(url: "https://github.com/caplaz/reports-swift.git", from: "0.3.0")
```

and add the `ReportsKit` product to your app target.

## Usage

### 1. Declare your operations

Handled errors are reported under an *operation*: a static name for the place in your code
where the failure happened. Declare them once:

```swift
import ReportsKit

extension CrashReporting.Operation {
    static let exportSave = Self("exportSave")
    static let deviceStart = Self("deviceStart")
}
```

Raw values become the `report.op` tag and part of the event fingerprint. They must be static
identifiers written in source code — **never** user data such as file names, paths or text.

### 2. Start at launch, on the main thread

```swift
@main
struct MyApp: App {
    init() {
        #if !DEBUG
        if let configuration = CrashReportingConfiguration.standard(
            dsn: "https://<publicKey>@reports.example.com/<projectId>",
            describeError: { error in
                // The ONLY error text that leaves the device. Never include paths, file
                // names, URLs, localizedDescription or userInfo values.
                let nsError = error as NSError
                return "\(type(of: error)) code=\(nsError.code)"
            },
            environmentResolver: {
                // Optional: refine the environment after start (e.g. "testflight").
                // Return nil to keep the initial environment ("production").
                nil
            }
        ) {
            CrashReporting.start(
                enabled: CrashReportingPreference.isEnabled(),
                configuration: configuration
            )
        }
        #endif
    }
    // ...
}
```

`start` must run on the main thread (sentry-cocoa 9.24.0 installs its hub synchronously only
when started on main; `start` traps otherwise). `standard(dsn:)` returns `nil` for an empty
DSN, so a build without a DSN simply never starts reporting.

`CrashReportingConfiguration.standard` fills the release name
(`<bundleID>@<version>+<build>`, the format `sentry-cli` uses for dSYM uploads), the cache
directory (`Caches/CrashReporting`) and a 5% traces sample rate. Use the memberwise
initializer to set them yourself.

### 3. Wire the settings toggle

```swift
Toggle("Send crash reports", isOn: Binding(
    get: { CrashReportingPreference.isEnabled() },
    set: { CrashReporting.setEnabled($0) }
))
```

`CrashReportingPreference` stores the choice in `UserDefaults` under `crashReportingEnabled`
(default **on**). `setEnabled` persists it and applies it immediately.

### 4. Capture handled errors

```swift
do {
    try export(to: url)
} catch {
    CrashReporting.capture(error, operation: .exportSave)
}
```

`capture` sends only the operation and `describeError(error)` — never the error value, its
description or `userInfo`. It is a no-op before `start`, while reporting is off, or when the
SDK is not running.

### 5. Send structured logs (optional)

For failures that are worth knowing about but not worth an event — a fallback path, a
retry, a degraded mode — send a structured log:

```swift
CrashReporting.log(.warning, "Falling back to software rendering", operation: .deviceStart)

do {
    try cache.write(entry)
} catch {
    CrashReporting.log(.error, error, operation: .exportSave)
}
```

- **Levels:** only `.warning` and `.error` exist.
- **Message variant:** the body is the message, a `StaticString` — a compile-time constant,
  so it cannot carry user data.
- **Error variant:** the body is `"<operation> <describeError(error)>"`, never the error's
  own text, `localizedDescription` or `userInfo`.
- **Attributes sent:** `report.op`, `report.error` (error variant only, =
  `describeError(error)`), `report.source = "reportskit"`, and the SDK's non-identifying
  `sentry.release`, `sentry.environment`, `sentry.sdk.name`, `sentry.sdk.version`,
  `os.name`, `os.version`, `device.brand`, `device.model`, `device.family`. Each log also
  carries a timestamp, level and the SDK's per-process trace id.
- **Never sent:** `user.id` (sentry-cocoa adds the installation ID to every log; it is
  stripped), `user.name`/`user.email`, replay ids, message templates/parameters, scope
  attributes, device name, or anything path-like.
- **Throttle:** at most one identical log — same level, operation and body — per 60 seconds
  per process; repeats inside the window are dropped on the device. The SDK batches the rest
  (up to 100 logs per envelope, flushed every 5 seconds).
- **No-op** before `start`, while reporting is off, when the SDK isn't running, or with
  `logsEnabled: false` in the configuration (which also sets the SDK's `enableLogs` to
  `false`). Logs default to on.
- Only logs sent through `CrashReporting.log` leave the device. Anything else that reaches
  the SDK's log pipeline — `SentrySDK.logger` called directly, a logging-framework bridge —
  is dropped by the sanitizer.

### 6. Detailed diagnostics (optional)

Offer a second, opt-in setting next to the first one. It is stored by ReportsKit and read
when the SDK starts, so a change applies at the next launch:

```swift
Toggle("Share detailed diagnostics", isOn: Binding(
    get: { CrashReportingPreference.isDetailedDiagnosticsEnabled() },
    set: { CrashReporting.setDetailedDiagnosticsEnabled($0) }
))
.disabled(!CrashReportingPreference.isEnabled())
```

With both settings on at start, `CrashReporting.activeProfile == .diagnostic`. Forward your
app's own log lines (info and above) only then:

```swift
if CrashReporting.activeProfile == .diagnostic {
    myLogger.onLine = { level, category, message in
        CrashReporting.forwardLog(level, category: category, message: message)
    }
}
```

`forwardLog` is a no-op in `strict`, while reporting is off, or with `logsEnabled: false`.
It is budgeted (an identical line once per 10 s, 120 lines per minute, 5,000 per process;
the next sent line carries `report.dropped`) and emits on a background queue, so it is safe
on hot threads. Tell users exactly what the setting sends — see the table below.

## Privacy guarantees

### Privacy profiles

| | `strict` (default) | `diagnostic` (opt-in) |
|---|---|---|
| Handled-error text | `describeError` only | + the error's own description and file/URL user info (exception value) |
| Stack frames / images | image last path component | + frame file names, full image paths |
| Logs | `CrashReporting.log` only | + `forwardLog` lines (`report.category`), `report.error.detail` |
| Installation ID | stripped everywhere | `user.id` on events and logs |
| Sessions | yes, random ID per launch | yes, installation ID |
| Metrics | off | ingestion path enabled, consent-gated — unused today (ReportsKit has no metrics producer yet) |
| Device name, IP, screenshots, view hierarchy | never | never |

The profile is chosen once per SDK start: `diagnostic` only when both
`CrashReportingPreference.isEnabled()` and `isDetailedDiagnosticsEnabled()` are on. There is
no override. When a launch goes from `diagnostic` back to `strict`, or starts with reporting
off, everything collected but not yet sent is deleted before the SDK starts; if that deletion
fails (fail-closed), it stays pending and the SDK does not start until it succeeds. Every
launch tags its scope with `report.profile`, which crash and hang reports keep from the
moment they are collected; a report replayed later is sanitized with the more private of that
tag and the current profile (untagged = `strict`). The tag sent is the profile actually
applied.

Release-health sessions run only while reporting is on. In `strict`, sentry-cocoa's
`INSTALLATION` file (the session `did` and the default `user.id`) is deleted at every start,
so each launch gets a new random, unlinkable session identifier; the first launch after
opting into `diagnostic` deletes and regenerates it too, so the new stable diagnostic
identifier is never retroactively linked to an earlier anonymous session, after which it
stays stable across diagnostic launches. A session left open by a force quit is closed as
abnormal at the next start.

Turning reporting off marks the scope `report.consent=off` (never sent) and pauses app-hang
tracking, marking the scope `report.hangs=off` for the rest of the process so a hang whose
detection straddles the opt-out is dropped too; anything collected under either marker — say,
a crash during the opted-out period, replayed at the next launch — is dropped. Tracing
(`tracesSampleRate`) is gated by consent the same way, independent of profile: a transaction
is sampled only while reporting is on, and one that spans or finishes during an opted-out
interval is still dropped before sending, even if its processing runs after re-enable.

### Allowlist sanitizer

`beforeSend`, `beforeBreadcrumb`, `beforeSendSpan` and `beforeSendLog` run every payload
through an allowlist (`CrashReportSanitizer`). It mutates the SDK's objects in place — sentry-cocoa casts the
`beforeSend` result of a transaction back to its private class — and the tests assert on the
complete envelope bytes captured at the transport, not on the callback's return value.

**Kept:** exception type and mechanism (type, handled flag, signal/Mach codes); stack frames
with instruction addresses, function names, in-app flags and the image name reduced to its
last path component; debug images with UUID, addresses, size, arch and `code_file` reduced to
its last path component; OS name/version/build; device model, arch, memory and CPU counts;
app identifier, version and build; release and environment; tags `report.op` and
`report.error`; breadcrumb type, category, level, timestamp and data keys `screen`/`state`;
transaction and span ops, ids, timestamps, status, frame counts, and span descriptions only
for app-start and `ui.load` spans (class names); for logs, only those emitted by
`CrashReporting.log` (matched by marker, level and body on the emitting thread), with the
attributes listed under [Send structured logs](#5-send-structured-logs-optional).

**Removed:** exception reasons (`value` becomes `<redacted>`), event messages, `user`,
`extra`, request data, server name, modules, logger, every non-allowlisted tag or context
key, stack-frame file names/source context/variables, breadcrumb messages and other data
keys, span data and descriptions outside the allowlist, every log not emitted by
`CrashReporting.log`, and every log attribute outside the allowlist (including the
installation-ID `user.id` the SDK adds to logs).

### Transport-level consent gate

Callbacks alone cannot enforce an opt-out: sentry-cocoa's `close()` flushes, and cached
envelopes are retried without passing through `beforeSend`. So ReportsKit hands the SDK a
`URLSession` whose first protocol is `ConsentURLProtocol`. A request is forwarded only if the
`ConsentGate` admits it; admission and revocation share one lock, so turning reporting off
either prevents admission or cancels the admitted upload. A refused, cancelled or unreadable
request fails without an HTTP response, which makes sentry-cocoa keep the envelope on disk
instead of sending or deleting it.

### Opt-out semantics

- **Turning reporting off** (`setEnabled(false)`) blocks all further uploads — events,
  transactions and logs, including logs already batched by the SDK — cancels in-flight ones,
  makes the SDK callbacks drop new data, and persists the choice. The SDK is
  never closed (closing would flush).
- **Launching with reporting off** does not start the SDK and deletes the cache directory,
  discarding everything that was queued but never delivered.
- **Turning reporting back on** resumes the gate and drains the queue in the same session, or
  starts the SDK if it was off at launch.
- **In-flight boundary:** an upload cancelled at the moment of opt-out may already have
  delivered some or all of its bytes; such a report may be ingested. No upload is *admitted*
  after the toggle flips.

### What is not sent

In the `strict` profile: no user or installation identifier (the SDK's installation ID is
stripped from every event and log, and the file holding it is deleted at every start, so
release-health sessions carry an identifier that is new for each launch), no file names or
paths, no error text beyond `describeError`, no forwarded app logs, no metrics. In every
profile: no screenshots or view hierarchies, no device or computer name, no network
breadcrumbs or network/file-I/O/Core Data tracing, no failed-request events for the app's
own `URLSession`s, and no client reports. `CrashReporting` has no metrics producer, so no
metrics are sent in either profile today even though `diagnostic` enables the ingestion path.
With a proxy DSN, Sentry sees the proxy's egress IP instead of the user's.

## sentry-cocoa is pinned exactly

`Package.swift` pins sentry-cocoa with `exact: "9.24.0"`. The consent gate and sanitizer rely
on behaviors of that version: envelopes are kept on disk only for connection-level failures
(any HTTP 4xx/5xx deletes them), `close()` flushes, events and logs carry a cached
installation-ID user, the installation ID (session `did`) lives in
`<cacheDirectory>/INSTALLATION` and is regenerated when that file is missing, crash and
stored-hang reports keep their collection-time scope tags and the current scope never
overrides them, the `@_spi(Private)` session/file-manager/envelope API `CachedSessionRecovery`
uses to close a force-quit launch's session (the hub's own method isn't public), session
envelopes bypass `beforeSend`, transactions are re-serialized from the root tracer after
`beforeSend`, and `beforeSendLog` runs synchronously on the thread that emitted the log (see
`docs/specs/2026-10-13-logs-design.md`). **Bumping the version requires re-running the full
test suite** (`swift test --no-parallel`), and any change in those behaviors must be handled
before releasing.

### Known SDK race

In sentry-cocoa 9.24.0 a single `SentrySDK.flush` is not a delivery barrier: right after
`start`, a reachability-triggered drain can race a capture and leave the new envelope on disk
with no drain scheduled (a lost wakeup in the transport). In an app this only delays
delivery — the envelope is sent at the next capture, connectivity change, flush or launch.
The tests use `SDKHarness.flush(until:)`, which flushes repeatedly until the expected outcome
is observable.

## Development

```sh
swift test
swift test --no-parallel -Xswiftc -warnings-as-errors   # what CI runs
```

Tests never touch the network: a recording `URLProtocol` sits behind the consent protocol.

## License

MIT — see [LICENSE](LICENSE).
