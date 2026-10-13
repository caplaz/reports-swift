import Foundation
import Sentry

/// Allowlist sanitizer (README "Privacy guarantees"). Mutates the SDK's objects in place and
/// returns the same instance — never a new `Event` — because sentry-cocoa casts the
/// `beforeSend` result of a transaction back to its private `SentryTransaction` class.
enum CrashReportSanitizer {
    static let redacted = "<redacted>"
    static let allowedTagKeys: Set<String> = ["report.op", "report.error"]
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
    /// Attributes sentry-cocoa 9.24.0's scope applier adds that identify nothing about the
    /// user or the device instance. Everything else it adds — `user.id` (the installation ID),
    /// `user.name`, `user.email`, `sentry.replay_id`, scope attributes — is stripped.
    static let allowedLogSDKAttributeKeys: Set<String> = [
        "sentry.release", "sentry.environment", "sentry.sdk.name", "sentry.sdk.version",
        "os.name", "os.version", "device.brand", "device.model", "device.family"
    ]
    static let allowedLogAttributeKeys: Set<String> = allowedLogSDKAttributeKeys.union([
        logOperationKey, logErrorKey, logSourceKey
    ])

    @discardableResult
    static func sanitize(_ event: Event) -> Event {
        event.user = nil
        event.extra = nil
        event.request = nil
        event.error = nil
        event.message = nil
        event.serverName = nil
        event.modules = nil
        event.logger = nil
        event.tags = event.tags?.filter { allowedTagKeys.contains($0.key) }
        event.context = sanitize(context: event.context)
        event.breadcrumbs = event.breadcrumbs?.compactMap { sanitize($0) }
        for exception in event.exceptions ?? [] {
            if exception.value != nil { exception.value = redacted }
            if let mechanism = exception.mechanism {
                mechanism.desc = nil
                mechanism.data = nil
                mechanism.helpLink = nil
            }
            exception.stacktrace.map(sanitize(stacktrace:))
        }
        for thread in event.threads ?? [] {
            thread.stacktrace.map(sanitize(stacktrace:))
        }
        event.stacktrace.map(sanitize(stacktrace:))
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map(lastPathComponent)
        }
        if event.type == "transaction" {
            sanitizeTransactionSpans(event)
        }
        return event
    }

    static func sanitize(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        breadcrumb.message = nil
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
    /// carrying our marker, with the same level and body; rebuilds its attributes from
    /// `expected` plus the SDK allowlist. Returns `nil` (drop) for anything else.
    static func sanitize(log: SentryLog, expected: ExpectedLog?) -> SentryLog? {
        guard let expected,
              log.attributes[logSourceKey]?.value as? String == logSource,
              expected.attributes[logSourceKey] == logSource,
              log.level == expected.level,
              log.body == expected.body else { return nil }
        var attributes = log.attributes.filter { allowedLogSDKAttributeKeys.contains($0.key) }
        for (key, value) in expected.attributes {
            attributes[key] = SentryAttribute(string: value)
        }
        log.attributes = attributes
        log.body = expected.body
        log.level = expected.level
        return log
    }

    static func keepsDescription(operation: String) -> Bool {
        operation.hasPrefix("app.start") || describedSpanOps.contains(operation)
    }

    static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func sanitize(stacktrace: SentryStacktrace) {
        for frame in stacktrace.frames {
            frame.fileName = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
            frame.package = frame.package.map(lastPathComponent)
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
