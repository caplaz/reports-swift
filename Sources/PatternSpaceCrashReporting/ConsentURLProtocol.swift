import Foundation

/// First protocol of the URLSession handed to Sentry (`Options.urlSession`). Requests are
/// forwarded through an inner session only when `ConsentGate.shared` admits them. A refused
/// or revoked request fails with no HTTP response, which makes sentry-cocoa 9.24.0 keep the
/// envelope on disk instead of sending or deleting it (spec §3).
final class ConsentURLProtocol: URLProtocol, @unchecked Sendable {
    /// Tests swap this for a configuration whose protocol records instead of networking.
    nonisolated(unsafe) static var innerConfiguration: URLSessionConfiguration = .ephemeral

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
    }

    private let box = TaskBox()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var forwarded = request
        if forwarded.httpBody == nil, let stream = request.httpBodyStream {
            // Deviation from plan: do NOT also assign `forwarded.httpBodyStream = nil` here.
            // On this Foundation, URLRequest's httpBodyStream setter clears httpBody as a
            // side effect even when passed nil, so that extra assignment silently wiped the
            // body we just set and sent an empty envelope. Setting httpBody alone already
            // clears any stream (verified empirically), so the explicit nil-out is both
            // redundant and harmful.
            forwarded.httpBody = Data(reading: stream)
        }
        let session = URLSession(configuration: Self.innerConfiguration)
        let box = self.box
        let task = ConsentGate.shared.admit {
            let task = session.dataTask(with: forwarded) { [weak self] data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let task = box.task { ConsentGate.shared.finished(task) }
                guard let self else { return }
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
            box.task = task
            return task
        }
        guard let task else {
            session.invalidateAndCancel()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        task.resume()
    }

    override func stopLoading() {
        box.task?.cancel()
    }
}
