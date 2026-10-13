import Foundation

/// At most one log per `(level, operation, body)` per `interval`, per process.
final class LogThrottle: @unchecked Sendable {
    struct Key: Hashable {
        let level: CrashReporting.LogLevel
        let operation: CrashReporting.Operation
        let body: String
    }

    static let defaultInterval: TimeInterval = 60
    /// Above this many tracked keys, expired ones are dropped on the next admission.
    static let pruneThreshold = 256

    private let lock = NSLock()
    private let interval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var lastAdmitted: [Key: TimeInterval] = [:]

    /// `now` must be monotonic (default: `ProcessInfo.systemUptime`).
    init(
        interval: TimeInterval = LogThrottle.defaultInterval,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.interval = interval
        self.now = now
    }

    var trackedKeyCount: Int { lock.withLock { lastAdmitted.count } }

    func admit(_ key: Key) -> Bool {
        lock.withLock {
            let time = now()
            if let last = lastAdmitted[key], time - last < interval { return false }
            lastAdmitted[key] = time
            if lastAdmitted.count > Self.pruneThreshold {
                lastAdmitted = lastAdmitted.filter { time - $0.value < interval }
            }
            return true
        }
    }
}
