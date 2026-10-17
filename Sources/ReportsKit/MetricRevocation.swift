import Foundation

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
    /// cutoff nothing is parsed. Otherwise the body is gunzipped and its item headers are read
    /// (`EnvelopeItems`); only `trace_metric` payloads are parsed. Any `trace_metric` item
    /// holding a pre-cutoff metric, or a metric without a readable timestamp, swallows the whole
    /// envelope (metric envelopes have one item in 9.24.0, spec §2.5.4).
    func checkedVerdict(forRequestBody body: Data) -> CheckedVerdict {
        let (cutoff, epoch) = lock.withLock { (self.cutoff, self.epoch) }
        guard let cutoff else { return CheckedVerdict(verdict: .forward, epoch: epoch) }
        return CheckedVerdict(verdict: Self.verdict(forRequestBody: body, cutoff: cutoff), epoch: epoch)
    }

    /// Wire-check seam: `false` makes every verdict `.forward`, so a test can isolate what the
    /// opt-out's forced flush and sweep delete on their own. Reset by `CrashReporting.resetForTesting()`.
    nonisolated(unsafe) static var wireCheckEnabledForTesting = true

    private static func verdict(forRequestBody body: Data, cutoff: TimeInterval) -> Verdict {
        guard wireCheckEnabledForTesting else { return .forward }
        // Unreadable (a stream that can't be inflated, or an envelope whose item headers can't
        // be walked): refused, and so kept on disk, only when a metric item may be in it. Any
        // other envelope goes through the normal gate path, so one unreadable non-metric
        // envelope can't block the upload queue for the rest of the process. A stream that
        // can't be inflated can't be read by the server either.
        guard let plain = gunzip(body) else { return EnvelopeItems.mayHoldMetric(body) ? .refuse : .forward }
        guard let items = EnvelopeItems(plain) else { return EnvelopeItems.mayHoldMetric(plain) ? .refuse : .forward }
        for payload in items.metricPayloads {
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
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
    /// (`SentryURLRequestFactory.swift:30-38`); the optional fields (RFC 1952 §2.3.1) are
    /// skipped anyway. Apple's `.zlib` decodes raw DEFLATE. Data that isn't gzip is returned
    /// unchanged; a gzip stream this can't read gives `nil`.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(2))
        guard bytes == [0x1F, 0x8B] else { return data }
        let start = data.startIndex
        // ID1 ID2 CM FLG MTIME(4) XFL OS, then the optional fields, the stream, CRC32 and ISIZE.
        guard data.count > 18, data[start + 2] == 8 else { return nil }
        let flags = data[start + 3]
        guard flags & 0xE0 == 0 else { return nil }   // reserved bits
        var offset = start + 10
        let end = data.endIndex - 8
        if flags & 0x04 != 0 {   // FEXTRA: 2-byte little-endian length, then that many bytes
            guard offset + 2 <= end else { return nil }
            offset += 2 + (Int(data[offset]) | (Int(data[offset + 1]) << 8))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT: zero-terminated
            guard offset < end, let zero = data[offset..<end].firstIndex(of: 0) else { return nil }
            offset = zero + 1
        }
        if flags & 0x02 != 0 { offset += 2 }   // FHCRC
        guard offset < end else { return nil }   // also catches an FEXTRA length past the end
        return try? (data.subdata(in: offset..<end) as NSData).decompressed(using: .zlib) as Data
    }
}

/// The items of a serialized envelope, read from their header lines only (spec §4.2): each
/// item header is one JSON line with `"type"` and, as sentry-cocoa 9.24.0 always writes it,
/// `"length"` (the payload's byte count; without it the payload runs to the next newline, per
/// the envelope protocol). Payloads are skipped, not parsed, so deciding whether an envelope
/// holds a metric costs a few small JSON lines.
struct EnvelopeItems {
    /// Whether any item is a `trace_metric`.
    private(set) var hasMetric = false
    /// The payloads of the `trace_metric` items.
    private(set) var metricPayloads: [Data] = []

    static let metricType = "trace_metric"
    private static let newline = UInt8(ascii: "\n")

    /// `nil` when the header lines can't be walked: no envelope header line, an item header that
    /// isn't a JSON object with a string `type`, or a `length` past the end of the data.
    init?(_ data: Data) {
        guard var offset = data.firstIndex(of: Self.newline).map({ $0 + 1 }) else { return nil }
        while offset < data.endIndex {
            let lineEnd = data[offset...].firstIndex(of: Self.newline) ?? data.endIndex
            let line = data[offset..<lineEnd]
            if line.allSatisfy({ $0 == Self.newline || $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
                offset = lineEnd + 1   // trailing newline / blank separator
                continue
            }
            guard let header = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = header["type"] as? String else { return nil }
            let payloadStart = min(lineEnd + 1, data.endIndex)
            let payloadEnd: Data.Index
            if let length = (header["length"] as? NSNumber)?.intValue {
                guard length >= 0, length <= data.endIndex - payloadStart else { return nil }
                payloadEnd = payloadStart + length
            } else {
                payloadEnd = data[payloadStart...].firstIndex(of: Self.newline) ?? data.endIndex
            }
            if type == Self.metricType {
                hasMetric = true
                metricPayloads.append(data.subdata(in: payloadStart..<payloadEnd))
            }
            offset = payloadEnd
            if offset < data.endIndex, data[offset] == Self.newline { offset += 1 }
        }
    }

    /// Fallback for data `init` can't walk: whether a `trace_metric` item header may be in it
    /// (the type name appears anywhere in the bytes). Conservative: a false positive only keeps
    /// an unreadable envelope on disk.
    static func mayHoldMetric(_ data: Data) -> Bool {
        data.range(of: Data(metricType.utf8)) != nil
    }
}

