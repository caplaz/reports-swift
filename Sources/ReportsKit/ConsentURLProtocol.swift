import Foundation

/// First protocol of the URLSession handed to Sentry (`Options.urlSession`). Requests are
/// forwarded through an inner session only when `ConsentGate.shared` admits them. A refused
/// or revoked request fails with no HTTP response, which makes sentry-cocoa 9.24.0 keep the
/// envelope on disk instead of sending or deleting it. A metric batch admitted before an
/// opt-out is answered with 200 and never forwarded (`MetricRevocation.checkedVerdict`). The
/// verdict is bound to its revocation epoch and re-validated atomically with gate admission
/// (`ConsentGate.admit(while:_:)`).
final class ConsentURLProtocol: URLProtocol, @unchecked Sendable {
    /// Tests swap this for a configuration whose protocol records instead of networking.
    nonisolated(unsafe) static var innerConfiguration: URLSessionConfiguration = .ephemeral

    /// Wire verdict + admission attempts per request before refusing. Each `.stale` retry needs
    /// a whole opt-out between verdict and admission, so a second attempt almost always settles.
    static let maxDecisions = 3

    /// Test seam: runs on the loading thread after each wire verdict, before gate admission,
    /// with the request body and the verdict. Reset by `CrashReporting.resetForTesting()`.
    nonisolated(unsafe) static var afterVerdictForTesting: ((Data, MetricRevocation.Verdict) -> Void)?

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
        // Weak at the outer closure: the completion handler below reaches `self` through it
        // (a weak capture only in the inner closure would make this one capture `self` strongly).
        let makeTask = { [weak self] () -> URLSessionTask in
            let task = session.dataTask(with: forwarded) { data, response, error in
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
        let body = forwarded.httpBody ?? Data()
        var admitted: URLSessionTask?
        decision: for _ in 0..<Self.maxDecisions {
            // Metrics admitted before an opt-out are never delivered (metrics spec §4.2): answer
            // a pre-cutoff metric batch with 200 so sentry-cocoa deletes it unsent
            // (`SentryHttpTransport.m:433-447`); refuse an unreadable body that may hold a
            // metric (kept on disk). An unreadable body without one takes the normal gate path.
            let revocation = CrashReporting.metricRevocation
            let checked = revocation.checkedVerdict(forRequestBody: body)
            Self.afterVerdictForTesting?(body, checked.verdict)
            switch checked.verdict {
            case .forward:
                break
            case .swallow:
                session.invalidateAndCancel()
                deliver { [weak self] in
                    guard let self, let url = self.request.url,
                          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
                    else { return }
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocolDidFinishLoading(self)
                }
                return
            case .refuse:
                session.invalidateAndCancel()
                deliver { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
                }
                return
            }
            // Admitted only if no opt-out started a new revocation epoch since the verdict,
            // checked under the gate's lock (`ConsentGate.admit(while:_:)`).
            switch ConsentGate.shared.admit(while: { revocation.isCurrent(epoch: checked.epoch) }, makeTask) {
            case .admitted(let task):
                admitted = task
                break decision
            case .closed:
                break decision
            case .stale:
                continue decision   // opted out (and back in) since the verdict: decide again
            }
        }
        // Closed gate, or consent kept changing under every decision: refuse (fail closed; the
        // envelope stays on disk).
        guard let task = admitted else {
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
