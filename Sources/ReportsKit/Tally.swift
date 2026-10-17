import Foundation

extension CrashReporting {
    /// Adds up a high-frequency counter (e.g. per-frame events) without SDK work on the hot
    /// path: `add` only takes uncontended locks (the consent check's and its own). The first
    /// `add` at least `interval` after the window opened records the sum with
    /// `CrashReporting.count`, and `flush` records whatever is pending (call it when the
    /// activity ends). Counter metrics only. Safe from any thread.
    ///
    /// Consent (metrics spec §3, decision 9): `add` is a no-op while metrics can't be recorded
    /// (reporting off). A pending total belongs to the consent period (revocation epoch) it was
    /// counted in. After an opt-out it is discarded, never sent, also after a re-enable, and
    /// its emission is admitted only while that epoch is still current.
    public final class Tally: @unchecked Sendable {
        public let metric: Metric
        private let interval: TimeInterval
        private let now: @Sendable () -> TimeInterval
        private let consent: @Sendable () -> UInt64?
        private let emit: @Sendable (UInt, UInt64) -> Void
        private let lock = NSLock()
        private var pending: UInt = 0
        /// The epoch `pending` was counted in; `nil` when nothing is pending.
        private var pendingEpoch: UInt64?
        private var windowStart: TimeInterval?

        public convenience init(_ metric: Metric, attributes: [String: String] = [:], interval: TimeInterval = 60) {
            self.init(metric, attributes: attributes, interval: interval,
                      now: { ProcessInfo.processInfo.systemUptime },
                      consent: { CrashReporting.metricEpoch() },
                      emit: { value, epoch in CrashReporting.count(metric, value, attributes: attributes, epoch: epoch) })
        }

        /// `now` must be monotonic. `consent` returns the current revocation epoch while metrics
        /// may be recorded, else `nil`. `emit` must admit only while its epoch is current.
        init(
            _ metric: Metric, attributes: [String: String], interval: TimeInterval,
            now: @escaping @Sendable () -> TimeInterval,
            consent: @escaping @Sendable () -> UInt64?,
            emit: @escaping @Sendable (UInt, UInt64) -> Void
        ) {
            assert(metric.kind == .counter, "Tally needs a counter metric, got \(metric.name)")
            self.metric = metric
            self.interval = interval
            self.now = now
            self.consent = consent
            self.emit = emit
        }

        public func add(_ value: UInt = 1) {
            // Reporting off (or metrics revoked): nothing is counted.
            guard let epoch = consent() else { return }
            let due: (value: UInt, epoch: UInt64)? = lock.withLock {
                let time = now()
                if pendingEpoch != epoch {
                    // Counted before the latest opt-out (or nothing pending): discard and start
                    // this epoch's total and window.
                    pending = 0
                    windowStart = nil
                    pendingEpoch = epoch
                }
                let (sum, overflow) = pending.addingReportingOverflow(value)
                pending = overflow ? .max : sum
                guard let start = windowStart else {
                    windowStart = time
                    return nil
                }
                guard time - start >= interval else { return nil }
                defer {
                    pending = 0
                    windowStart = time
                }
                return (pending, epoch)
            }
            if let due, due.value > 0 { emit(due.value, due.epoch) }
        }

        public func flush() {
            let current = consent()
            let due: (value: UInt, epoch: UInt64)? = lock.withLock {
                defer {
                    pending = 0
                    pendingEpoch = nil
                    windowStart = nil
                }
                // A total from an earlier epoch, or reporting off now: discarded.
                guard let epoch = pendingEpoch, epoch == current, pending > 0 else { return nil }
                return (pending, epoch)
            }
            if let due { emit(due.value, due.epoch) }
        }
    }
}
