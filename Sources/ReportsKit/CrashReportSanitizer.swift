import Foundation
import Sentry

/// Allowlist sanitizer (README "Privacy guarantees" and "Privacy profiles"). Mutates the SDK's
/// objects in place and returns the same instance — never a new `Event` — because
/// sentry-cocoa casts the `beforeSend` result of a transaction back to its private
/// `SentryTransaction` class. Every rule defaults to `.strict`; `.diagnostic` relaxes only the
/// rules listed in spec §5.
enum CrashReportSanitizer {
    typealias Profile = CrashReporting.PrivacyProfile

    static let redacted = "<redacted>"
    /// The profile an event was collected under (scope tag set at SDK start, persisted with
    /// stored crash/hang reports); `beforeSend` reads it and rewrites it to the applied profile.
    static let profileTagKey = "report.profile"
    /// Scope tag present only while the user has opted out in this process; `beforeSend` drops
    /// any event carrying it. Deliberately **not** in `allowedTagKeys`: never sent.
    static let consentTagKey = "report.consent"
    static let consentOffValue = "off"
    /// Scope tag set at the first opt-out of a process and never removed in it; marks hangs
    /// whose detection could have overlapped the opted-out interval. Never sent (not in
    /// `allowedTagKeys`).
    static let hangsTagKey = "report.hangs"

    /// sentry-cocoa marks app-hang events with mechanism type `AppHang`
    /// (`SentryHangTrackingIntegration.swift:108`).
    static func isAppHang(_ event: Event) -> Bool {
        event.exceptions?.contains { $0.mechanism?.type == "AppHang" } ?? false
    }

    static let allowedTagKeys: Set<String> = ["report.op", "report.error", profileTagKey]
    static let allowedContextKeys: [String: Set<String>] = [
        "os": ["name", "version", "build", "rooted"],
        "device": [
            "family", "model", "model_id", "arch", "memory_size", "processor_count",
            "simulator", "orientation", "thermal_state"
        ],
        "app": [
            "app_identifier", "app_name", "app_version", "app_build", "build_type",
            "in_foreground", "is_active", "app_start_time", "app_memory"
        ],
        "trace": ["trace_id", "span_id", "parent_span_id", "op", "status", "origin", "type"]
    ]
    static let allowedBreadcrumbDataKeys: Set<String> = ["screen", "state"]
    static let allowedSpanDataKeys: Set<String> = [
        "thread.id", "thread.name", "frames.total", "frames.slow", "frames.frozen"
    ]
    static let describedSpanOps: Set<String> = [
        "ui.load", "ui.load.initial_display", "ui.load.full_display"
    ]

    // MARK: Logs

    static let logOperationKey = "report.op"
    static let logErrorKey = "report.error"
    static let logSourceKey = "report.source"
    static let logSource = "reportskit"
    static let logEnvironmentKey = "sentry.environment"
    /// Diagnostic profile only.
    static let logErrorDetailKey = "report.error.detail"
    static let logCategoryKey = "report.category"
    static let logDroppedKey = "report.dropped"
    static let forwardedLogSource = "app-log"
    static let logUserIDKey = "user.id"
    /// Attributes sentry-cocoa 9.24.0's scope applier can produce that identify nothing about
    /// the user or the device instance. Everything else it adds — `user.id` (the installation
    /// ID), `user.name`, `user.email`, `sentry.replay_id`, scope attributes — is stripped
    /// (`user.id` is kept in the diagnostic profile).
    static let allowedLogSDKAttributeKeys: Set<String> = [
        "sentry.release", "sentry.environment", "sentry.sdk.name", "sentry.sdk.version",
        "os.name", "os.version", "device.brand", "device.model", "device.family"
    ]
    /// Every attribute a strict log can carry.
    static let allowedLogAttributeKeys: Set<String> = allowedLogSDKAttributeKeys.union([
        logOperationKey, logErrorKey, logSourceKey
    ])
    static let diagnosticLogAttributeKeys: Set<String> = [
        logUserIDKey, logErrorDetailKey, logCategoryKey, logDroppedKey
    ]

    static func allowedLogSources(_ profile: Profile) -> Set<String> {
        profile == .diagnostic ? [logSource, forwardedLogSource] : [logSource]
    }

    static func allowedLogAttributeKeys(_ profile: Profile) -> Set<String> {
        profile == .diagnostic ? allowedLogAttributeKeys.union(diagnosticLogAttributeKeys) : allowedLogAttributeKeys
    }

    @discardableResult
    static func sanitize(_ event: Event, profile: Profile = .strict) -> Event {
        let detailed = profile == .diagnostic
        // Diagnostic: only the installation ID the SDK set; never email/username/IP/geo/data.
        event.user = detailed ? event.user?.userId.map { User(userId: $0) } : nil
        event.extra = nil
        event.request = nil
        event.error = nil
        event.message = nil
        event.serverName = nil
        event.modules = nil
        event.logger = nil
        event.tags = event.tags?.filter { allowedTagKeys.contains($0.key) }
        event.context = sanitize(context: event.context)
        event.breadcrumbs = event.breadcrumbs?.compactMap { sanitize($0, profile: profile) }
        for exception in event.exceptions ?? [] {
            if !detailed, exception.value != nil { exception.value = redacted }
            if let mechanism = exception.mechanism {
                if !detailed {
                    mechanism.desc = nil
                    mechanism.data = nil
                }
                mechanism.helpLink = nil
            }
            exception.stacktrace.map { sanitize(stacktrace: $0, profile: profile) }
        }
        for thread in event.threads ?? [] {
            thread.stacktrace.map { sanitize(stacktrace: $0, profile: profile) }
        }
        event.stacktrace.map { sanitize(stacktrace: $0, profile: profile) }
        if !detailed {
            for image in event.debugMeta ?? [] {
                image.codeFile = image.codeFile.map(lastPathComponent)
            }
        }
        if event.type == "transaction" {
            sanitizeTransactionSpans(event)
        }
        return event
    }

    static func sanitize(_ breadcrumb: Breadcrumb, profile: Profile = .strict) -> Breadcrumb? {
        if profile == .strict { breadcrumb.message = nil }
        // The `data` property setter is deprecated in 9.24.0 in favor of per-key mutation
        // (see setData(value:key:)); removing disallowed keys one at a time keeps this
        // warning-free under -warnings-as-errors while producing the same allowlisted result.
        if let data = breadcrumb.data {
            for key in data.keys where !allowedBreadcrumbDataKeys.contains(key) {
                breadcrumb.setData(value: nil, key: key)
            }
        }
        return breadcrumb
    }

    static func sanitize(span: Span) {
        for key in span.data.keys where !allowedSpanDataKeys.contains(key) {
            span.removeData(key: key)
        }
        for key in span.tags.keys where !allowedTagKeys.contains(key) {
            span.removeTag(key: key)
        }
        if !keepsDescription(operation: span.operation) {
            span.spanDescription = nil
        }
    }

    /// Keeps only a log that ReportsKit is emitting on this thread right now (`expected`),
    /// whose `report.source` marker is allowed for `profile` and matches, with the same level
    /// and body; rebuilds its attributes from `expected` (filtered to the profile's keys) plus
    /// the SDK allowlist. Returns `nil` (drop) for anything else.
    ///
    /// `environment`, when present, overrides the `sentry.environment` attribute sentry-cocoa's
    /// scope applier set from `Options.environment` at `start` — it never re-reads the scope, so
    /// a resolved `CrashReportingConfiguration.environmentResolver` name never reaches logs on
    /// its own (unlike events, which do pick it up via `configureScope`).
    static func sanitize(
        log: SentryLog, expected: ExpectedLog?, environment: String? = nil, profile: Profile = .strict
    ) -> SentryLog? {
        guard let expected,
              let source = expected.attributes[logSourceKey],
              allowedLogSources(profile).contains(source),
              log.attributes[logSourceKey]?.value as? String == source,
              log.level == expected.level,
              log.body == expected.body else { return nil }
        let sdkKeys = profile == .diagnostic
            ? allowedLogSDKAttributeKeys.union([logUserIDKey]) : allowedLogSDKAttributeKeys
        var attributes = log.attributes.filter { sdkKeys.contains($0.key) }
        let ownKeys = allowedLogAttributeKeys(profile)
        for (key, value) in expected.attributes where ownKeys.contains(key) {
            attributes[key] = SentryAttribute(string: value)
        }
        if let environment {
            attributes[logEnvironmentKey] = SentryAttribute(string: environment)
        }
        log.attributes = attributes
        log.body = expected.body
        log.level = expected.level
        if let timestamp = expected.timestamp { log.timestamp = timestamp }
        return log
    }

    static func keepsDescription(operation: String) -> Bool {
        operation.hasPrefix("app.start") || describedSpanOps.contains(operation)
    }

    static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func sanitize(stacktrace: SentryStacktrace, profile: Profile) {
        for frame in stacktrace.frames {
            if profile == .strict {
                frame.fileName = nil
                frame.package = frame.package.map(lastPathComponent)
            }
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }

    private static func sanitize(
        context: [String: [String: Any]]?
    ) -> [String: [String: Any]]? {
        guard let context else { return nil }
        var result: [String: [String: Any]] = [:]
        for (name, values) in context {
            guard let allowed = allowedContextKeys[name] else { continue }
            result[name] = values.filter { allowed.contains($0.key) }
        }
        return result
    }

    /// Root tracer and child spans of a (private) `SentryTransaction`. Its `serialize` re-reads
    /// `trace.data`/`trace.tags`/`trace.spanDescription` after `beforeSend`, so they must be
    /// cleaned on the objects themselves.
    private static func sanitizeTransactionSpans(_ event: Event) {
        let traceSelector = NSSelectorFromString("trace")
        if event.responds(to: traceSelector), let root = event.value(forKey: "trace") as? Span {
            sanitize(span: root)
        }
        let spansSelector = NSSelectorFromString("spans")
        if event.responds(to: spansSelector), let spans = event.value(forKey: "spans") as? [Span] {
            spans.forEach(sanitize(span:))
        }
    }
}
