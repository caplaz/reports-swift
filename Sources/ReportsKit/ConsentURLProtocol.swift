import Foundation

/// First protocol of the URLSession handed to Sentry (`Options.urlSession`). Requests are
/// forwarded through an inner session only when `ConsentGate.shared` admits them. A refused
/// or revoked request fails with no HTTP response, which makes sentry-cocoa 9.24.0 keep the
/// envelope on disk instead of sending or deleting it.
final class ConsentURLProtocol: URLProtocol, @unchecked Sendable {
    /// Tests swap this for a configuration whose protocol records instead of networking.
    nonisolated(unsafe) static var innerConfiguration: URLSessionConfiguration = .ephemeral

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
    }

    private let box = TaskBox()

    /// The inner session's completion handler fires on a session-managed queue, not
    /// necessarily the thread/run loop that called `startLoading`. `URLProtocol` requires
    /// client callbacks to be delivered back on that original thread/run loop, so it's
    /// captured here and every callback is hopped onto it via `RunLoop.perform`.
    private let stateLock = NSLock()
    private var callbackRunLoop: RunLoop?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        stateLock.withLock {
            callbackRunLoop = RunLoop.current
            stopped = false
        }
        var forwarded = request
        if forwarded.httpBody == nil, let stream = request.httpBodyStream {
            // Deviation from plan: do NOT also assign `forwarded.httpBodyStream = nil` here.
            // On this Foundation, URLRequest's httpBodyStream setter clears httpBody as a
            // side effect even when passed nil, so that extra assignment silently wiped the
            // body we just set and sent an empty envelope. Setting httpBody alone already
            // clears any stream (verified empirically), so the explicit nil-out is both
            // redundant and harmful.
            guard let body = Data(reading: stream) else {
                // A stream read error must not forward a truncated envelope as if it were
                // complete. Fail with no response, the same connection-level contract as an
                // admission refusal, so sentry-cocoa keeps the envelope queued on disk.
                deliver { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                }
                return
            }
            forwarded.httpBody = body
        }
        let session = URLSession(configuration: Self.innerConfiguration)
        let box = self.box
        let task = ConsentGate.shared.admit {
            let task = session.dataTask(with: forwarded) { [weak self] data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let task = box.task { ConsentGate.shared.finished(task) }
                guard let self else { return }
                self.deliver {
                    if let response {
                        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    }
                    if let data { self.client?.urlProtocol(self, didLoad: data) }
                    if let error {
                        self.client?.urlProtocol(self, didFailWithError: error)
                    } else {
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
            }
            box.task = task
            return task
        }
        guard let task else {
            session.invalidateAndCancel()
            deliver { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
            return
        }
        task.resume()
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        box.task?.cancel()
    }

    /// Hops `work` onto the thread/run loop that called `startLoading`, and drops it if
    /// `stopLoading` has already fired (checked both now and again right before `work` runs,
    /// since `stopLoading` can land on another thread between scheduling and execution).
    private func deliver(_ work: @escaping () -> Void) {
        let (runLoop, alreadyStopped) = stateLock.withLock { (callbackRunLoop, stopped) }
        guard !alreadyStopped else { return }
        guard let runLoop else {
            // No captured run loop (shouldn't happen outside tests that call startLoading
            // directly off any scheduled load) — fall back to calling inline.
            work()
            return
        }
        runLoop.perform(inModes: [.common]) { [weak self] in
            guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
            work()
        }
    }
}
