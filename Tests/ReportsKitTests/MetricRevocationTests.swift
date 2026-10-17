import Foundation
// SentryEnvelope/Item/Header, SentryEnvelopeItemTypes, SentryNSURLRequestBuilder are SPI in
// sentry-cocoa 9.24.0 (private interface `:117-129`, `:814-821`, `:1311-1315`, `:1644-1646`, `:1793-1803`).
@_spi(Private) import Sentry
import Testing
@testable import ReportsKit

@Suite struct MetricRevocationTests {
    /// A one-item `trace_metric` envelope as `TelemetryScheduler` builds it, with one metric.
    static func metricEnvelope(timestamp: Date, name: String = "test.count") -> SentryEnvelope {
        let payload = #"{"items":[{"timestamp":\#(timestamp.timeIntervalSince1970),"name":"\#(name)","type":"counter","value":1,"trace_id":"0123456789abcdef0123456789abcdef","attributes":{}}]}"#
        let item = SentryEnvelopeItem(
            type: SentryEnvelopeItemTypes.traceMetric, data: Data(payload.utf8),
            contentType: "application/vnd.sentry.items.trace-metric+json", itemCount: 1)
        return SentryEnvelope(header: SentryEnvelopeHeader.empty(), singleItem: item)
    }

    static func eventEnvelope() -> SentryEnvelope {
        SentryEnvelope(header: SentryEnvelopeHeader.empty(), singleItem: SentryEnvelopeItem(event: Event(level: .error)))
    }

    /// The upload body exactly as sentry-cocoa builds it (gzipped, `SentryURLRequestFactory.swift:30-38`).
    static func body(_ envelope: SentryEnvelope) throws -> Data {
        let request = try SentryNSURLRequestBuilder().createEnvelopeRequest(
            envelope, url: URL(string: "https://reports.example.test/api/7/envelope/")!)
        return try #require(request.httpBody)
    }

    @Test func timestampsStrictlyIncreaseEvenWhenTheClockStepsBack() throws {
        let clock = Locked<Date>(Date(timeIntervalSince1970: 1_700_000_000))
        let revocation = MetricRevocation(now: { clock.value })
        let first = try #require(revocation.admit())
        let second = try #require(revocation.admit())                 // same clock reading
        clock.value = clock.value.addingTimeInterval(-3_600)           // clock set back an hour
        let third = try #require(revocation.admit())
        // ≈ one step apart (Date stores seconds since 2001, so allow rounding, never reordering).
        #expect(second.timeIntervalSince1970 - first.timeIntervalSince1970 > MetricRevocation.step / 2)
        #expect(third.timeIntervalSince1970 - second.timeIntervalSince1970 > MetricRevocation.step / 2)
        #expect(third < first.addingTimeInterval(1))   // never jumps ahead more than needed
    }

    @Test func revokeStopsAdmissionAndCutsOffEverythingIssued() throws {
        let revocation = MetricRevocation()
        let before = try #require(revocation.admit())
        #expect(!revocation.isRevoked(before))
        revocation.revoke()
        #expect(revocation.admit() == nil)
        #expect(revocation.isRevoked(before))
        revocation.reopen()
        let after = try #require(revocation.admit())
        #expect(!revocation.isRevoked(after))
        #expect(after > before)
    }

    @Test func revokeBeforeAnyMetricSetsNoCutoff() {
        let revocation = MetricRevocation()
        revocation.revoke()
        #expect(!revocation.hasCutoff)
        revocation.reopen()
        #expect(revocation.admit() != nil)
    }

    @Test func wireVerdicts() throws {
        let revocation = MetricRevocation()
        let old = try #require(revocation.admit())
        let oldBody = try Self.body(Self.metricEnvelope(timestamp: old))
        // Never opted out: forwarded without parsing.
        #expect(revocation.verdict(forRequestBody: oldBody) == .forward)
        revocation.revoke()
        revocation.reopen()
        let new = try #require(revocation.admit())
        let newBody = try Self.body(Self.metricEnvelope(timestamp: new))
        let eventBody = try Self.body(Self.eventEnvelope())
        #expect(revocation.verdict(forRequestBody: oldBody) == .swallow)
        #expect(revocation.verdict(forRequestBody: newBody) == .forward)
        #expect(revocation.verdict(forRequestBody: eventBody) == .forward)
        // A metric item without a readable timestamp counts as revoked.
        let broken = SentryEnvelopeItem(
            type: SentryEnvelopeItemTypes.traceMetric, data: Data(#"{"items":[{}]}"#.utf8),
            contentType: "application/vnd.sentry.items.trace-metric+json", itemCount: 1)
        let brokenBody = try Self.body(SentryEnvelope(header: SentryEnvelopeHeader.empty(), singleItem: broken))
        #expect(revocation.verdict(forRequestBody: brokenBody) == .swallow)
        // A gzip stream with optional header fields (never produced by the SDK) is still read.
        #expect(revocation.verdict(forRequestBody: Self.withFileName(oldBody)) == .swallow)
        #expect(revocation.verdict(forRequestBody: Self.withFileName(newBody)) == .forward)
    }

    /// `body` with an FNAME field in its gzip header (RFC 1952 §2.3.1).
    static func withFileName(_ body: Data) -> Data {
        var header = Data(body.prefix(10))
        header[header.startIndex + 3] |= 0x08
        return header + Data("envelope.json\0".utf8) + body.dropFirst(10)
    }

    /// Review finding: an unreadable body is refused (kept on disk) only when a metric item may
    /// be in it; any other unreadable body takes the normal gate path, so it can't block the
    /// upload queue for the rest of the process.
    @Test func unreadableBodiesAreRefusedOnlyWhenTheyMayHoldAMetric() throws {
        let revocation = MetricRevocation()
        _ = try #require(revocation.admit())
        revocation.revoke()
        revocation.reopen()
        // A gzip stream that can't be inflated (corrupt DEFLATE data): no readable metric.
        var corrupt = try Self.body(Self.eventEnvelope())
        for index in (corrupt.startIndex + 10)..<(corrupt.startIndex + 16) { corrupt[index] = 0xFF }
        #expect(MetricRevocation.gunzip(corrupt) == nil)
        #expect(revocation.verdict(forRequestBody: corrupt) == .forward)
        // Plain bodies whose item headers can't be walked.
        let brokenEvent = Data("{}\n{\"type\":\"event\",\"length\":999}\n{}".utf8)
        #expect(revocation.verdict(forRequestBody: brokenEvent) == .forward)
        let brokenMetric = Data("{}\n{\"type\":\"trace_metric\",\"length\":999}\n{}".utf8)
        #expect(revocation.verdict(forRequestBody: brokenMetric) == .refuse)
        let garbledHeader = Data("{}\nnot json, but trace_metric\n{}".utf8)
        #expect(revocation.verdict(forRequestBody: garbledHeader) == .refuse)
        #expect(revocation.verdict(forRequestBody: Data("no envelope header".utf8)) == .forward)
    }

    /// Envelope items are found from their header lines alone (spec §4.2).
    @Test func envelopeItemsAreReadFromTheirHeaderLines() throws {
        let metric = try #require(MetricRevocation.gunzip(Self.body(Self.metricEnvelope(timestamp: Date()))))
        let items = try #require(EnvelopeItems(metric))
        #expect(items.hasMetric)
        #expect(items.metricPayloads.count == 1)
        let payload = try #require(items.metricPayloads.first)
        #expect((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["items"] != nil)

        let event = try #require(MetricRevocation.gunzip(Self.body(Self.eventEnvelope())))
        let eventItems = try #require(EnvelopeItems(event))
        #expect(!eventItems.hasMetric)
        #expect(eventItems.metricPayloads.isEmpty)

        // A payload containing newlines and the type name is skipped by length, then the next
        // item (a metric without explicit length: runs to the next newline) is found.
        let tricky = "{\"type\":\"trace_metric\"}\n"
        let mixed = Data(("{}\n{\"type\":\"attachment\",\"length\":\(tricky.utf8.count)}\n" + tricky
            + "\n{\"type\":\"trace_metric\"}\n{\"items\":[]}\n").utf8)
        let mixedItems = try #require(EnvelopeItems(mixed))
        #expect(mixedItems.hasMetric)
        #expect(mixedItems.metricPayloads == [Data(#"{"items":[]}"#.utf8)])
        let attachmentOnly = Data(("{}\n{\"type\":\"attachment\",\"length\":\(tricky.utf8.count)}\n" + tricky).utf8)
        #expect(EnvelopeItems(attachmentOnly)?.hasMetric == false)

        #expect(EnvelopeItems(Data("{}".utf8)) == nil)                                    // no header line
        #expect(EnvelopeItems(Data("{}\n{\"length\":2}\n{}".utf8)) == nil)                  // no type
        #expect(EnvelopeItems(Data("{}\n{\"type\":\"event\",\"length\":50}\n{}".utf8)) == nil)   // past the end
        #expect(EnvelopeItems.mayHoldMetric(Data("x trace_metric y".utf8)))
        #expect(!EnvelopeItems.mayHoldMetric(Data("{\"type\":\"event\"}".utf8)))
    }

    @Test func everyRevokeStartsANewEpochAndOldEpochsAreNotAdmitted() throws {
        let revocation = MetricRevocation()
        let first = try #require(revocation.currentEpoch)
        #expect(revocation.isCurrent(epoch: first))
        #expect(revocation.admit(epoch: first) != nil)
        revocation.revoke()
        #expect(revocation.currentEpoch == nil)              // admission closed
        #expect(!revocation.isCurrent(epoch: first))
        revocation.reopen()
        let second = try #require(revocation.currentEpoch)
        #expect(second != first)
        #expect(revocation.admit(epoch: first) == nil)       // accumulated before the opt-out
        #expect(revocation.admit(epoch: second) != nil)
        #expect(revocation.admit() != nil)                   // untagged admission is unaffected
        // A revoke with nothing issued yet sets no cutoff but still starts a new epoch.
        let empty = MetricRevocation()
        let before = try #require(empty.currentEpoch)
        empty.revoke()
        empty.reopen()
        #expect(!empty.hasCutoff)
        #expect(!empty.isCurrent(epoch: before))
    }

    @Test func checkedVerdictRecordsTheEpochItWasDecidedUnder() throws {
        let revocation = MetricRevocation()
        let old = try #require(revocation.admit())
        let body = try Self.body(Self.metricEnvelope(timestamp: old))
        let before = revocation.checkedVerdict(forRequestBody: body)
        #expect(before.verdict == .forward)                  // no cutoff yet
        #expect(revocation.isCurrent(epoch: before.epoch))
        revocation.revoke()
        revocation.reopen()
        // The verdict above is stale: an opt-out happened since. Decided again, it swallows.
        #expect(!revocation.isCurrent(epoch: before.epoch))
        let after = revocation.checkedVerdict(forRequestBody: body)
        #expect(after.verdict == .swallow)
        #expect(revocation.isCurrent(epoch: after.epoch))
        #expect(revocation.verdict(forRequestBody: body) == after.verdict)
    }
}
