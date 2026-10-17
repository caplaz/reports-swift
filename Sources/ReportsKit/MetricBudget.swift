import Foundation

/// Volume caps for metrics (spec §6): at most `perMinute` per 60-second window and `perProcess`
/// per process. Dropped metrics are counted; the count is reported (as
/// `reportskit.metrics.dropped`) with the next admitted metric.
final class MetricBudget: @unchecked Sendable {
    static let window: TimeInterval = 60
    static let defaultPerMinute = 60
    static let defaultPerProcess = 3_000

    private let lock = NSLock()
    private let perMinute: Int
    private let perProcess: Int
    private let now: @Sendable () -> TimeInterval
    private var windowStart: TimeInterval?
    private var windowCount = 0
    private var total = 0
    private var dropped = 0

    /// `now` must be monotonic (default: `ProcessInfo.systemUptime`).
    init(
        perMinute: Int = MetricBudget.defaultPerMinute,
        perProcess: Int = MetricBudget.defaultPerProcess,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.perMinute = perMinute
        self.perProcess = perProcess
        self.now = now
    }

    /// Metrics dropped since the previous admitted one, or `nil` when this one is dropped.
    func admit() -> Int? {
        lock.withLock {
            let time = now()
            if let start = windowStart, time - start < Self.window {
                // Same window.
            } else {
                windowStart = time
                windowCount = 0
            }
            guard windowCount < perMinute, total < perProcess else {
                dropped += 1
                return nil
            }
            windowCount += 1
            total += 1
            let count = dropped
            dropped = 0
            return count
        }
    }
}
