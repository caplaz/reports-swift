import Foundation
import Sentry

extension CrashReporting {
    /// Metrics are handed to the SDK here, off the caller's thread (metrics spec §3).
    static let metricQueue = DispatchQueue(label: "io.caplaz.ReportsKit.metrics", qos: .utility)

    /// Recorded after budget overflow with the number of metrics dropped since the last one sent.
    static let droppedMetric = Metric("reportskit.metrics.dropped", kind: .counter)

    /// Adds `value` to a counter. A no-op before `start`, while reporting is off, when the SDK
    /// isn't running or with `metricsEnabled == false`. Safe to call from any thread; cheap on
    /// the caller (lock-only admission). Attributes are filtered by the declaration.
    public static func count(_ metric: Metric, _ value: UInt = 1, attributes: [String: String] = [:]) {
        guard metric.kind == .counter else { return kindMismatch(metric, .counter) }
        record(metric, value: .counter(value), attributes: attributes)
    }

    /// Records one value of a distribution, in the metric's unit. Same rules as `count`.
    public static func distribution(_ metric: Metric, _ value: Double, attributes: [String: String] = [:]) {
        guard metric.kind == .distribution else { return kindMismatch(metric, .distribution) }
        guard value.isFinite else { return }
        record(metric, value: .distribution(value), attributes: attributes)
    }

    /// Records the current value of a gauge, in the metric's unit. Same rules as `count`.
    public static func gauge(_ metric: Metric, _ value: Double, attributes: [String: String] = [:]) {
        guard metric.kind == .gauge else { return kindMismatch(metric, .gauge) }
        guard value.isFinite else { return }
        record(metric, value: .gauge(value), attributes: attributes)
    }

    /// Records the time elapsed since `start` on a distribution whose unit is `.millisecond` or
    /// `.second`. `outcome`, when given, is added as the `outcome` attribute.
    public static func duration(
        _ metric: Metric, since start: ContinuousClock.Instant, attributes: [String: String] = [:],
        outcome: String? = nil
    ) {
        assert(metric.unit == .millisecond || metric.unit == .second, "\(metric.name) is not a time metric")
        var attributes = attributes
        if let outcome { attributes[Metric.outcomeKey] = outcome }
        distribution(metric, metric.value(of: start.duration(to: .now)), attributes: attributes)
    }

    /// Runs `body` and records its duration with `outcome` = `success`, `cancelled`
    /// (`CancellationError`) or `failure`; rethrows.
    @discardableResult
    public static func measure<T>(
        _ metric: Metric, attributes: [String: String] = [:], _ body: () throws -> T
    ) rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try body()
            duration(metric, since: start, attributes: attributes, outcome: "success")
            return result
        } catch {
            duration(metric, since: start, attributes: attributes, outcome: outcome(of: error))
            throw error
        }
    }

    /// Async variant of `measure`.
    @discardableResult
    public static func measure<T>(
        _ metric: Metric, attributes: [String: String] = [:], _ body: () async throws -> T
    ) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try await body()
            duration(metric, since: start, attributes: attributes, outcome: "success")
            return result
        } catch {
            duration(metric, since: start, attributes: attributes, outcome: outcome(of: error))
            throw error
        }
    }

    static func outcome(of error: any Error) -> String {
        error is CancellationError ? "cancelled" : "failure"
    }

    private static func kindMismatch(_ metric: Metric, _ expected: Metric.Kind) {
        assertionFailure("\(metric.name) is a \(metric.kind.rawValue) metric, not a \(expected.rawValue)")
    }

    /// Admission on the caller's thread; the SDK call on `metricQueue`.
    static func record(_ metric: Metric, value: SentryMetricValue, attributes: [String: String]) {
        guard canRecordMetric(), let dropped = metricBudget.admit() else { return }
        let expected = ExpectedMetric(
            name: metric.name, value: value, unit: metric.sentryUnit,
            attributes: metric.filtered(attributes), timestamp: Date())
        metricQueue.async {
            emit(expected)
            if dropped > 0 {
                emit(ExpectedMetric(
                    name: droppedMetric.name, value: .counter(UInt(dropped)), unit: nil,
                    attributes: [:], timestamp: expected.timestamp))
            }
        }
    }

    private static func emit(_ metric: ExpectedMetric) {
        // Consent may have been turned off since admission (metrics spec §4.1).
        guard ConsentGate.shared.isEnabled, SentrySDK.isEnabled else { return }
        let attributes = metric.attributes.mapValues { $0 as any SentryAttributeValue }
        // beforeSendMetric runs synchronously on this thread and matches the pending metric.
        PendingMetric.with(metric) {
            switch metric.value {
            case .counter(let value):
                SentrySDK.metrics.count(key: metric.name, value: value, attributes: attributes)
            case .distribution(let value):
                SentrySDK.metrics.distribution(key: metric.name, value: value, unit: metric.unit, attributes: attributes)
            case .gauge(let value):
                SentrySDK.metrics.gauge(key: metric.name, value: value, unit: metric.unit, attributes: attributes)
            @unknown default:
                // `SentryMetricValue` is non-frozen (library evolution); ReportsKit only builds
                // the three cases above, so a newer SDK kind is never emitted.
                break
            }
        }
    }
}

extension CrashReporting.Metric {
    var sentryUnit: SentryUnit? {
        switch unit {
        case .none: nil
        case .millisecond: .millisecond
        case .second: .second
        case .byte: .byte
        case .percent: .percent
        case .ratio: .ratio
        }
    }

    /// `duration` in this metric's unit: seconds for `.second`, else milliseconds.
    func value(of duration: Duration) -> Double {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return unit == .second ? seconds : seconds * 1_000
    }
}
