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
        // A gzip stream with optional header fields (never produced by the SDK) can't be read:
        // refused, neither forwarded nor swallowed.
        var unreadable = newBody
        unreadable[unreadable.startIndex + 3] = 0x08   // FNAME flag
        #expect(revocation.verdict(forRequestBody: unreadable) == .refuse)
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
