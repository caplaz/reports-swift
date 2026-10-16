import Foundation
import Testing
@testable import ReportsKit

@Suite(.serialized) struct TraceConsentTests {
    @Test func admitsOnlyWhileConsentedAndRevocationForgets() {
        let consent = TraceConsent()
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

    // Review finding: the sampler doesn't roll; it hands the configured rate to the SDK, which
    // rolls and reports it as the transaction's `sample_rate`.
    @Test func admissionReturnsTheConfiguredRate() {
        let consent = TraceConsent()
        consent.setConsented(true)
        #expect(consent.admit(key: "a", rate: 0.05).doubleValue == 0.05)
        #expect(consent.consume(key: "a"))
        consent.setConsented(false)
        #expect(consent.admit(key: "b", rate: 0.05).doubleValue == 0)
    }

    @Test func admissionsAreCappedOldestFirst() {
        let consent = TraceConsent()
        consent.setConsented(true)
        for index in 0...TraceConsent.maxAdmitted { _ = consent.admit(key: "k\(index)", rate: 1) }
        #expect(!consent.consume(key: "k0"))
        #expect(consent.consume(key: "k1"))
        #expect(consent.consume(key: "k\(TraceConsent.maxAdmitted)"))
    }

    // Regression (review): revocation racing an admission that already passed the consent
    // check cannot leave the admission alive.
    @Test func revocationWaitsForAnInFlightAdmissionAndForgetsIt() {
        let consent = TraceConsent()
        consent.setConsented(true)
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0)
        let admitted = DispatchSemaphore(value: 0)
        consent.afterConsentCheckForTesting = { paused.signal(); resume.wait() }
        Thread { _ = consent.admit(key: "t", rate: 1); admitted.signal() }.start()
        // The admission is past the consent check, holding the lock.
        #expect(paused.wait(timeout: .now() + 5) == .success)
        Thread { consent.setConsented(false); revoked.signal() }.start()
        // The revocation is blocked behind the in-flight admission (proves the overlap).
        #expect(revoked.wait(timeout: .now() + 0.2) == .timedOut)
        consent.afterConsentCheckForTesting = nil
        resume.signal()
        #expect(admitted.wait(timeout: .now() + 5) == .success)
        #expect(revoked.wait(timeout: .now() + 5) == .success)
        consent.setConsented(true)                                        // re-enable
        #expect(!consent.consume(key: "t"))
    }
}
