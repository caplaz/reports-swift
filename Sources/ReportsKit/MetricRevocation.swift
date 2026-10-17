import Foundation
// SPI from the 9.24.0 binary's .private.swiftinterface (exact pin; re-verify on every bump):
// SentryEnvelope.items, SentryEnvelopeItem.type()/data, SentryEnvelopeItemTypes.traceMetric.
@_spi(Private) import Sentry

/// Metrics admitted before an opt-out are never delivered (metrics spec decision 9, §4.2).
///
/// ReportsKit issues every metric's timestamp here, strictly increasing within the process,
/// so "admitted before the latest opt-out" is exactly `timestamp ≤ cutoff`, whatever the wall
/// clock does. Admission and revocation share one lock: a racing `admit` gets a timestamp the
/// cutoff covers, or none. The cutoff is checked at emission, in `beforeSendMetric` and on
/// the wire (`verdict`), so a batch the SDK writes after the opt-out sweeps is still dropped.
///
/// Every `revoke` also starts a new **epoch**. The cutoff changes only in `revoke`, so a
/// decision taken under an epoch that is still current was taken against the current cutoff.
/// `ConsentURLProtocol` re-checks its wire verdict's epoch atomically with gate admission
/// (`ConsentGate.admit(while:_:)`), and `Tally` tags pending totals with the epoch they were
/// counted in and emits them only through `admit(epoch:)`.
final class MetricRevocation: @unchecked Sendable {
    /// Minimum spacing of issued timestamps: strictly increasing after the JSON round trip
    /// (seconds since 1970 as a Double, `InMemoryInternalTelemetryBuffer.swift:5-9`).
    static let step: TimeInterval = 0.001

    enum Verdict: Equatable {
        /// Not a pre-cutoff metric batch: send normally.
        case forward
        /// A pre-cutoff metric batch: answer 200 without sending, so the SDK deletes it.
        case swallow
        /// Unreadable while a cutoff exists: fail with no response (kept on disk).
        case refuse
    }

    /// A wire verdict and the epoch it was decided under. Valid only while
    /// `isCurrent(epoch:)`; after an opt-out it must be decided again.
    struct CheckedVerdict: Equatable {
        let verdict: Verdict
        let epoch: UInt64
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var lastIssued: TimeInterval?
    private var cutoff: TimeInterval?
    private var revoked = false
    private var epoch: UInt64 = 0

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The admission timestamp for a new metric, or `nil` between `revoke` and `reopen`, or
    /// when `epoch` is given and is no longer current (the value was accumulated before an
    /// opt-out: `Tally`, Task A6).
    func admit(epoch expected: UInt64? = nil) -> Date? {
        lock.withLock {
            guard !revoked, expected.map({ $0 == epoch }) ?? true else { return nil }
            var time = now().timeIntervalSince1970
            if let last = lastIssued, time < last + Self.step { time = last + Self.step }
            let date = Date(timeIntervalSince1970: time)
            // Exactly the value the SDK's encoder writes (`date.timeIntervalSince1970`), so the
            // cutoff compares like with like on the wire.
            lastIssued = date.timeIntervalSince1970
            return date
        }
    }

    /// Opt-out: everything issued so far is revoked; nothing is admitted until `reopen`. Starts
    /// a new epoch, also when nothing was issued yet (no cutoff).
    func revoke() {
        lock.withLock {
            revoked = true
            epoch &+= 1
            if let lastIssued { cutoff = lastIssued }
        }
    }

    /// Re-enable, after the pending metrics were swept. The cutoff stays for the process.
    func reopen() {
        lock.withLock { revoked = false }
    }

    var hasCutoff: Bool { lock.withLock { cutoff != nil } }

    /// The current epoch while admission is open; `nil` between `revoke` and `reopen`.
    var currentEpoch: UInt64? { lock.withLock { revoked ? nil : epoch } }

    /// Whether no opt-out (`revoke`) happened since `candidate` was read. Deliberately not tied
    /// to `revoked`: the gate's own state decides whether an upload may go now.
    func isCurrent(epoch candidate: UInt64) -> Bool {
        lock.withLock { candidate == epoch }
    }

    func isRevoked(_ timestamp: Date) -> Bool { isRevoked(seconds: timestamp.timeIntervalSince1970) }

    func isRevoked(seconds: TimeInterval) -> Bool {
        lock.withLock { cutoff.map { seconds <= $0 } ?? false }
    }

    /// `checkedVerdict(forRequestBody:).verdict`.
    func verdict(forRequestBody body: Data) -> Verdict {
        checkedVerdict(forRequestBody: body).verdict
    }

    /// What `ConsentURLProtocol` does with an upload body (spec §4.2 "Wire check"), and the
    /// epoch that decision belongs to. Cutoff and epoch are read together, once. Without a
    /// cutoff nothing is parsed. Otherwise the body is gunzipped and read with the SDK's own
    /// deserializer; any `trace_metric` item holding a pre-cutoff metric, or a metric without
    /// a readable timestamp, swallows the whole envelope (metric envelopes have one item in
    /// 9.24.0, spec §2.5.4).
    func checkedVerdict(forRequestBody body: Data) -> CheckedVerdict {
        let (cutoff, epoch) = lock.withLock { (self.cutoff, self.epoch) }
        guard let cutoff else { return CheckedVerdict(verdict: .forward, epoch: epoch) }
        return CheckedVerdict(verdict: Self.verdict(forRequestBody: body, cutoff: cutoff), epoch: epoch)
    }

    private static func verdict(forRequestBody body: Data, cutoff: TimeInterval) -> Verdict {
        guard let plain = gunzip(body), let envelope = PrivateSentrySDKOnly.envelope(with: plain) else {
            return .refuse
        }
        for item in envelope.items where item.type() == SentryEnvelopeItemTypes.traceMetric {
            guard let data = item.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metrics = json["items"] as? [[String: Any]] else { return .swallow }
            let pending = metrics.contains { metric in
                guard let seconds = metric["timestamp"] as? Double else { return true }
                return seconds <= cutoff
            }
            if pending { return .swallow }
        }
        return .forward
    }

    /// sentry-cocoa gzips upload bodies with zlib's gzip wrapper and no optional header fields
    /// (`SentryURLRequestFactory.swift:30-38`); Apple's `.zlib` decodes raw DEFLATE. Data that
    /// isn't gzip is returned unchanged; a gzip stream this can't read gives `nil`.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return data
        }
        guard data.count > 18, data[data.startIndex + 2] == 8, data[data.startIndex + 3] == 0 else { return nil }
        let deflated = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
