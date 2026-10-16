import Foundation

/// Volume caps for `CrashReporting.forwardLog` (spec §6.2): an identical line at most once per
/// `repeatInterval`, at most `perMinute` lines per 60-second window, at most `perProcess`
/// lines per process. Dropped lines are counted and reported on the next admitted one.
final class ForwardBudget: @unchecked Sendable {
    struct Key: Hashable {
        let level: CrashReporting.ForwardedLogLevel
        let category: String
        let body: String
    }

    static let maxBodyLength = 4_096
    static let repeatInterval: TimeInterval = 10
    static let window: TimeInterval = 60
    static let defaultPerMinute = 120
    static let defaultPerProcess = 5_000
    /// Above this many tracked keys, expired ones are dropped on the next admission.
    static let pruneThreshold = 256

    private let lock = NSLock()
    private let perMinute: Int
    private let perProcess: Int
    private let now: @Sendable () -> TimeInterval
    private var lastAdmitted: [Key: TimeInterval] = [:]
    private var windowStart: TimeInterval?
    private var windowCount = 0
    private var total = 0
    private var dropped = 0

    /// `now` must be monotonic (default: `ProcessInfo.systemUptime`).
    init(
        perMinute: Int = ForwardBudget.defaultPerMinute,
        perProcess: Int = ForwardBudget.defaultPerProcess,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.perMinute = perMinute
        self.perProcess = perProcess
        self.now = now
    }

    var trackedKeyCount: Int { lock.withLock { lastAdmitted.count } }

    /// Lines dropped since the previous admitted line, or `nil` when this one is dropped.
    func admit(_ key: Key) -> Int? {
        lock.withLock {
            let time = now()
            if let last = lastAdmitted[key], time - last < Self.repeatInterval {
                dropped += 1
                return nil
            }
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
            lastAdmitted[key] = time
            if lastAdmitted.count > Self.pruneThreshold {
                lastAdmitted = lastAdmitted.filter { time - $0.value < Self.repeatInterval }
            }
            let count = dropped
            dropped = 0
            return count
        }
    }

    static func truncated(_ message: String) -> String {
        message.count <= maxBodyLength ? message : String(message.prefix(maxBodyLength)) + "…"
    }
}
