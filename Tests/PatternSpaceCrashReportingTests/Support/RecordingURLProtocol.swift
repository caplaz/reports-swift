import Foundation
@testable import PatternSpaceCrashReporting

/// Stand-in for the network behind `ConsentURLProtocol`. Records delivered bodies.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case accept, failConnection, pauseBeforeDelivery }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _mode: Mode = .accept
    nonisolated(unsafe) private static var _bodies: [Data] = []
    nonisolated(unsafe) static var arrived = DispatchSemaphore(value: 0)
    nonisolated(unsafe) static var proceed = DispatchSemaphore(value: 0)

    static var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    static var bodies: [Data] { lock.withLock { _bodies } }

    /// Blocking semaphore waits are unavailable in async contexts (Swift 6 `noasync`), so
    /// wait on a detached thread.
    ///
    /// Deviation from plan: the `noasync` check is syntactic — it still fires for a call
    /// directly inside the `Task.detached` closure body (verified: `swiftc -warnings-as-errors`
    /// rejects it even though that body runs synchronously). Nesting the wait inside a
    /// `DispatchQueue.global().sync` closure keeps the immediate enclosing closure
    /// non-`async`, which satisfies the check while still blocking only the detached thread.
    static func waitForArrival(seconds: Double = 5) async -> Bool {
        let semaphore = arrived
        return await Task.detached {
            DispatchQueue.global().sync { semaphore.wait(timeout: .now() + seconds) == .success }
        }.value
    }

    static func reset(mode: Mode = .accept) {
        lock.withLock {
            _mode = mode
            _bodies = []
        }
        arrived = DispatchSemaphore(value: 0)
        proceed = DispatchSemaphore(value: 0)
        stopAcknowledged = DispatchSemaphore(value: 0)
    }

    static func installBehindConsentProtocol() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        ConsentURLProtocol.innerConfiguration = configuration
    }

    private let stoppedLock = NSLock()
    private var stopped = false
    nonisolated(unsafe) static var stopAcknowledged = DispatchSemaphore(value: 0)

    /// Awaits `stopLoading` on a paused request (cancellation acknowledged).
    /// See `waitForArrival` for why the wait is nested in `DispatchQueue.global().sync`.
    static func waitForStop(seconds: Double = 5) async -> Bool {
        let semaphore = stopAcknowledged
        return await Task.detached {
            DispatchQueue.global().sync { semaphore.wait(timeout: .now() + seconds) == .success }
        }.value
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap { Data(reading: $0) } ?? Data()
        switch Self.mode {
        case .failConnection:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .accept:
            deliver(body)
        case .pauseBeforeDelivery:
            Self.arrived.signal()
            DispatchQueue.global().async {
                _ = Self.proceed.wait(timeout: .now() + 10)
                // Check and record under the same lock stopLoading takes: no interleaving.
                let delivered: Bool = self.stoppedLock.withLock {
                    guard !self.stopped else { return false }
                    Self.lock.withLock { Self._bodies.append(body) }
                    return true
                }
                if delivered { self.respond() }
            }
        }
    }

    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
        Self.stopAcknowledged.signal()
    }

    private func deliver(_ body: Data) {
        Self.lock.withLock { Self._bodies.append(body) }
        respond()
    }

    private func respond() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"00000000000000000000000000000000"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
