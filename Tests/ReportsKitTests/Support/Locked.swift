import Foundation

/// A value shared between a test and the threads or callbacks it drives.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension DispatchSemaphore {
    /// Whether the semaphore was signalled within `seconds`. A synchronous wrapper, so async
    /// tests can block on purpose (e.g. on main, to prove an overlap) without the
    /// async-context `wait` diagnostic.
    func signalled(within seconds: Double) -> Bool {
        wait(timeout: .now() + seconds) == .success
    }
}
