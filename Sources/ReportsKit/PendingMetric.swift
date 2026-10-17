import Foundation
import Sentry

/// The metric `CrashReporting` is emitting: the only shape `beforeSendMetric` lets through.
struct ExpectedMetric: Equatable {
    let name: String
    let value: SentryMetricValue
    let unit: SentryUnit?
    /// Declaration-filtered app attributes (`Metric.filtered`).
    let attributes: [String: String]
    /// Admission time; replaces the SDK's (queue) timestamp.
    let timestamp: Date
}

/// Thread-local slot holding the metric being emitted on the current thread, so
/// `beforeSendMetric` — which sentry-cocoa 9.24.0 runs synchronously on the recording thread
/// (`SentryMetricsIntegration.swift:44-78`) — can tell ReportsKit's metrics from any other
/// (direct `SentrySDK.metrics` calls by the app or another library).
enum PendingMetric {
    private final class Box {
        let metric: ExpectedMetric
        init(_ metric: ExpectedMetric) { self.metric = metric }
    }

    private static let key = "io.caplaz.ReportsKit.pendingMetric"

    static var current: ExpectedMetric? {
        (Thread.current.threadDictionary[key] as? Box)?.metric
    }

    static func with<T>(_ metric: ExpectedMetric, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = Box(metric)
        defer { dictionary[key] = previous }
        return try body()
    }
}
