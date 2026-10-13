# reports-swift

Privacy-first crash reporting for Apple-platform apps. `ReportsKit` is a thin facade over
[sentry-cocoa](https://github.com/getsentry/sentry-cocoa) that:

- sends **no user content** — every event, breadcrumb and span is reduced to an allowlist
  before it is written to disk or sent;
- enforces the user's **opt-out at the transport level**, so nothing leaves the device once
  reporting is turned off — not even reports that were already queued;
- never attaches a **stable identifier** for the user or the device.

It is meant to be used with a DSN whose host is a reverse proxy you control (for example
[`reports.caplaz.com`](https://github.com/caplaz/reports-proxy), a Cloudflare Worker), so the
app never talks to `*.sentry.io` and Sentry never sees the user's IP address.

Requires macOS 15.4+ / iOS 18.4+, Swift 5.10+.

## Installation

```swift
.package(url: "https://github.com/caplaz/reports-swift.git", from: "0.1.0")
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

## Privacy guarantees

### Allowlist sanitizer

`beforeSend`, `beforeBreadcrumb` and `beforeSendSpan` run every payload through an allowlist
(`CrashReportSanitizer`). It mutates the SDK's objects in place — sentry-cocoa casts the
`beforeSend` result of a transaction back to its private class — and the tests assert on the
complete envelope bytes captured at the transport, not on the callback's return value.

**Kept:** exception type and mechanism (type, handled flag, signal/Mach codes); stack frames
with instruction addresses, function names, in-app flags and the image name reduced to its
last path component; debug images with UUID, addresses, size, arch and `code_file` reduced to
its last path component; OS name/version/build; device model, arch, memory and CPU counts;
app identifier, version and build; release and environment; tags `report.op` and
`report.error`; breadcrumb type, category, level, timestamp and data keys `screen`/`state`;
transaction and span ops, ids, timestamps, status, frame counts, and span descriptions only
for app-start and `ui.load` spans (class names).

**Removed:** exception reasons (`value` becomes `<redacted>`), event messages, `user`,
`extra`, request data, server name, modules, logger, every non-allowlisted tag or context
key, stack-frame file names/source context/variables, breadcrumb messages and other data
keys, span data and descriptions outside the allowlist.

### Transport-level consent gate

Callbacks alone cannot enforce an opt-out: sentry-cocoa's `close()` flushes, and cached
envelopes are retried without passing through `beforeSend`. So ReportsKit hands the SDK a
`URLSession` whose first protocol is `ConsentURLProtocol`. A request is forwarded only if the
`ConsentGate` admits it; admission and revocation share one lock, so turning reporting off
either prevents admission or cancels the admitted upload. A refused, cancelled or unreadable
request fails without an HTTP response, which makes sentry-cocoa keep the envelope on disk
instead of sending or deleting it.

### Opt-out semantics

- **Turning reporting off** (`setEnabled(false)`) blocks all further uploads, cancels
  in-flight ones, makes the SDK callbacks drop new data, and persists the choice. The SDK is
  never closed (closing would flush).
- **Launching with reporting off** does not start the SDK and deletes the cache directory,
  discarding everything that was queued but never delivered.
- **Turning reporting back on** resumes the gate and drains the queue in the same session, or
  starts the SDK if it was off at launch.
- **In-flight boundary:** an upload cancelled at the moment of opt-out may already have
  delivered some or all of its bytes; such a report may be ingested. No upload is *admitted*
  after the toggle flips.

### What is not sent

No user or installation identifier (the SDK's cached installation ID is stripped from every
event), no release-health sessions (they carry an installation-derived ID and bypass
`beforeSend`), no file names or paths, no error text beyond `describeError`, no screenshots
or view hierarchies, no network breadcrumbs or network/file-I/O/Core Data tracing, no
failed-request events for the app's own `URLSession`s, and no client reports. With a proxy
DSN, Sentry sees the proxy's egress IP instead of the user's.

## sentry-cocoa is pinned exactly

`Package.swift` pins sentry-cocoa with `exact: "9.24.0"`. The consent gate and sanitizer rely
on behaviors of that version: envelopes are kept on disk only for connection-level failures
(any HTTP 4xx/5xx deletes them), `close()` flushes, events carry a cached installation-ID user,
session envelopes bypass `beforeSend`, and transactions are re-serialized from the root
tracer after `beforeSend`. **Bumping the version requires re-running the full test suite**
(`swift test --no-parallel`), and any change in those behaviors must be handled before
releasing.

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
