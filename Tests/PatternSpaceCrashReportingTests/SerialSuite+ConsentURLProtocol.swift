import Foundation
import Testing
@testable import PatternSpaceCrashReporting

extension SerialSuite {
    private func outerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func envelopeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://reports.example.invalid/api/7/envelope/")!)
        request.httpMethod = "POST"
        request.httpBody = Data("envelope".utf8)
        return request
    }

    @Test func consentProtocolForwardsBodyWhileEnabled() async throws {
        RecordingURLProtocol.reset()
        RecordingURLProtocol.installBehindConsentProtocol()
        ConsentGate.shared.setEnabled(true)
        let (_, response) = try await outerSession().data(for: envelopeRequest())
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(RecordingURLProtocol.bodies == [Data("envelope".utf8)])
    }

    @Test func consentProtocolFailsWithoutResponseWhileDisabled() async {
        RecordingURLProtocol.reset()
        RecordingURLProtocol.installBehindConsentProtocol()
        ConsentGate.shared.setEnabled(false)
        await #expect(throws: URLError.self) {
            _ = try await outerSession().data(for: envelopeRequest())
        }
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }

    @Test func bodyStreamReadErrorFailsWithNoResponse() async {
        RecordingURLProtocol.reset()
        RecordingURLProtocol.installBehindConsentProtocol()
        ConsentGate.shared.setEnabled(true)
        var request = URLRequest(url: URL(string: "https://reports.example.invalid/api/7/envelope/")!)
        request.httpMethod = "POST"
        request.httpBodyStream = FailingAfterFirstReadInputStream()
        await #expect(throws: URLError.self) {
            _ = try await outerSession().data(for: request)
        }
        // No truncated envelope must reach the inner (recording) protocol.
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }

    @Test func optOutAfterAdmissionCancelsBeforeAnyByteIsDelivered() async throws {
        RecordingURLProtocol.reset(mode: .pauseBeforeDelivery)
        RecordingURLProtocol.installBehindConsentProtocol()
        ConsentGate.shared.setEnabled(true)
        let request = Task { try await outerSession().data(for: envelopeRequest()) }
        #expect(await RecordingURLProtocol.waitForArrival())
        ConsentGate.shared.setEnabled(false)
        #expect(await RecordingURLProtocol.waitForStop())   // cancellation reached the protocol
        RecordingURLProtocol.proceed.signal()
        await #expect(throws: (any Error).self) { _ = try await request.value }
        #expect(RecordingURLProtocol.bodies.isEmpty)
    }
}
