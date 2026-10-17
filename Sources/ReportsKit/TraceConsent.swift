import Foundation
import Sentry

/// Clock-free consent provenance for transactions (spec §3.2d). `tracesSampler` admits a
/// transaction's identity only while consent is on; revocation drops every admitted identity,
/// so a transaction that started before, during, or across an opt-out is never sent.
final class TraceConsent: @unchecked Sendable {
    static let shared = TraceConsent()
    static let maxAdmitted = 512

    private let lock = NSLock()
    /// Own consent flag, changed only by `setConsented` inside the serialized `setEnabled`
    /// transition (and `startSDK`), so the check and the admission are one atomic step against
    /// revocation.
    private var consented = false
    /// Admitted identities, oldest first, at most `maxAdmitted`. The SDK rolls the sample
    /// decision after admission, so unsampled transactions are admitted too; they never reach
    /// `beforeSend` and age out of the cap.
    private var admitted: [String] = []
    /// Test seam: runs inside the lock after the consent check, before admission.
    var afterConsentCheckForTesting: (() -> Void)?

    /// A transaction is identified by its trace ID AND root span ID: transactions may share a
    /// trace ID (`TransactionContext` accepts one), so the trace alone would let a transaction
    /// spanning an opt-out consume a newer one's admission.
    static func key(traceID: SentryId, spanID: SpanId) -> String {
        "\(traceID.sentryIdString):\(spanID.sentrySpanIdString)"
    }

    /// Called from `tracesSampler`. While consented, admits `key` and returns `rate`, so the
    /// SDK rolls the decision itself and reports the configured `sample_rate`; otherwise
    /// returns 0 (never sampled).
    func admit(key: String, rate: Double) -> NSNumber {
        lock.withLock {
            guard consented else { return 0 }
            afterConsentCheckForTesting?()
            admitted.append(key)
            if admitted.count > Self.maxAdmitted { admitted.removeFirst(admitted.count - Self.maxAdmitted) }
            return NSNumber(value: rate)
        }
    }

    /// Consent on: new transactions may be admitted. Consent off: forget every admission.
    func setConsented(_ value: Bool) {
        lock.withLock {
            consented = value
            if !value { admitted.removeAll() }
        }
    }

    /// The transaction's own root identity via the private `trace` property (KVC, guarded the
    /// same way as the sanitizer's transaction path). Nil for non-transactions. Never read from
    /// `event.context["trace"]`: at `beforeSend` that is the scope's bound span / propagation
    /// context (`SentryScope.m:690-723`), replaced by the transaction's own trace only in
    /// `serialize` (`SentryTransaction.m:108`).
    static func rootKey(of event: Event) -> String? {
        let object = event as NSObject
        guard object.responds(to: NSSelectorFromString("trace")),
              let span = object.value(forKey: "trace") as? Span else { return nil }
        return key(traceID: span.traceId, spanID: span.spanId)
    }

    /// Called from `beforeSend` for a transaction. True (and forgets the key) only if admitted
    /// in the current consent generation.
    func consume(key: String?) -> Bool {
        guard let key else { return false }
        return lock.withLock {
            guard let index = admitted.firstIndex(of: key) else { return false }
            admitted.remove(at: index)
            return true
        }
    }

    func resetForTesting() {
        setConsented(false)
        afterConsentCheckForTesting = nil
    }
}
