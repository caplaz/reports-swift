import Foundation

/// Admission and revocation of crash-report uploads under one lock. A task is
/// recorded as admitted before the lock is released, so `setEnabled(false)` either prevents
/// admission or sees — and cancels — the task. `admit(while:_:)` additionally binds an
/// admission to a caller's decision (the metric wire verdict's epoch).
final class ConsentGate: @unchecked Sendable {
    static let shared = ConsentGate()

    private let lock = NSLock()
    private var enabled = false
    private var admitted: [ObjectIdentifier: URLSessionTask] = [:]

    var isEnabled: Bool { lock.withLock { enabled } }
    var admittedCount: Int { lock.withLock { admitted.count } }

    func admit(_ makeTask: () -> URLSessionTask) -> URLSessionTask? {
        lock.withLock {
            guard enabled else { return nil }
            let task = makeTask()
            admitted[ObjectIdentifier(task)] = task
            return task
        }
    }

    enum Admission {
        case admitted(URLSessionTask)
        /// The gate is closed: refuse, as `admit(_:)` returning `nil`.
        case closed
        /// The gate is open but `isValid` failed: the caller's decision is out of date.
        case stale
    }

    /// `admit(_:)` that also requires `isValid()`, evaluated under the gate's lock. No
    /// `setEnabled(false)` … `setEnabled(true)` can fall between that check and the admission;
    /// one that starts after it cancels the admitted task as usual. `ConsentURLProtocol` passes
    /// "the wire verdict's revocation epoch is still current" (metrics spec §4.2). `isValid`
    /// must not take this gate's lock (it takes only `MetricRevocation`'s, which never takes the
    /// gate's).
    func admit(while isValid: () -> Bool, _ makeTask: () -> URLSessionTask) -> Admission {
        lock.withLock {
            guard enabled else { return .closed }
            guard isValid() else { return .stale }
            let task = makeTask()
            admitted[ObjectIdentifier(task)] = task
            return .admitted(task)
        }
    }

    func finished(_ task: URLSessionTask) {
        lock.withLock { admitted[ObjectIdentifier(task)] = nil }
    }

    func setEnabled(_ value: Bool) {
        let revoked: [URLSessionTask] = lock.withLock {
            enabled = value
            guard !value else { return [] }
            defer { admitted.removeAll() }
            return Array(admitted.values)
        }
        // Cancel outside the lock: completion handlers call `finished`, which takes it.
        revoked.forEach { $0.cancel() }
    }
}
