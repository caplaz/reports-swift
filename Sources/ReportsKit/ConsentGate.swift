import Foundation

/// Admission and revocation of crash-report uploads under one lock. A task is
/// recorded as admitted before the lock is released, so `setEnabled(false)` either prevents
/// admission or sees — and cancels — the task.
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
