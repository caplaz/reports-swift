import Foundation
import Testing
@testable import ReportsKit

@Suite(.serialized) struct TraceConsentTests {
    @Test func admitsOnlyWhileConsentedAndRevocationForgets() {
        let consent = TraceConsent()
        consent.random = { 0 }
        #expect(consent.admit(key: "a", rate: 1) == 0)
        consent.setConsented(true)
        #expect(consent.admit(key: "b", rate: 1) == 1)
        consent.setConsented(false)
        #expect(!consent.consume(key: "b"))
        consent.setConsented(true)
        #expect(consent.admit(key: "c", rate: 1) == 1)
        #expect(consent.consume(key: "c"))
        #expect(!consent.consume(key: "c"))
    }

    // Regression (review): revocation racing an admission that already passed the consent
    // check cannot leave the admission alive.
    @Test func revocationWaitsForAnInFlightAdmissionAndForgetsIt() async {
        let consent = TraceConsent()
        consent.random = { 0 }
        consent.setConsented(true)
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        consent.afterConsentCheckForTesting = { paused.signal(); resume.wait() }
        let sampler = Thread { _ = consent.admit(key: "t", rate: 1) }
        sampler.start()
        await Task.detached { DispatchQueue.global().sync { _ = paused.wait(timeout: .now() + 5) } }.value
        let revoker = Task.detached { consent.setConsented(false) }      // blocks on the lock
        try? await Task.sleep(nanoseconds: 100_000_000)
        consent.afterConsentCheckForTesting = nil
        resume.signal()
        await revoker.value
        consent.setConsented(true)                                        // re-enable
        #expect(!consent.consume(key: "t"))
    }
}
