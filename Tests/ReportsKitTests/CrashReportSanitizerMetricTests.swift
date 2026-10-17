import Foundation
@_spi(Private) import Sentry
import Testing
@testable import ReportsKit

/// `SentryMetric`'s initializer is `@_spi(Private)` in sentry-cocoa 9.24.0
/// (`arm64-apple-macos.private.swiftinterface`), hence the SPI import.
@Suite struct CrashReportSanitizerMetricTests {
    static let expected = ExpectedMetric(
        name: "test.duration", value: .distribution(12.5), unit: .millisecond,
        attributes: ["format": "cube", "outcome": "success"],
        timestamp: Date(timeIntervalSince1970: 1_000))
    static let trace = SentryId()

    /// What sentry-cocoa 9.24.0's scope applier can produce, plus planted junk.
    static func sdkEnriched(
        _ expected: ExpectedMetric, name: String? = nil, value: SentryMetricValue? = nil,
        unit: SentryUnit? = .millisecond
    ) -> SentryMetric {
        var attributes: [String: SentryAttributeContent] = expected.attributes.mapValues { .string($0) }
        let sdk: [String: String] = [
            "sentry.sdk.name": "sentry.cocoa",
            "sentry.sdk.version": "9.24.0",
            "sentry.environment": "production",
            "sentry.release": "com.example.MyApp@2.3+417",
            "os.name": "macOS",
            "os.version": "26.0",
            "device.brand": "Apple",
            "device.model": "Mac15,3",
            "device.family": "Mac",
            "user.id": "installation-id-123",
            "user.name": "Jane",
            "user.email": "jane@example.com",
            "sentry.replay_id": "replay-1",
            "device.name": "Jane's MacBook Pro",
            "file.path": "/Volumes/Work/x.profile"
        ]
        for (key, text) in sdk { attributes[key] = .string(text) }
        attributes["format"] = .string("/Users/jane/Client Smith.cube")   // forged own attribute
        var metric = SentryMetric(
            timestamp: Date(timeIntervalSince1970: 2_000), traceId: trace, name: name ?? expected.name,
            value: value ?? expected.value, unit: unit, attributes: attributes)
        metric.spanId = SpanId()
        return metric
    }

    static func strings(_ metric: SentryMetric) -> [String: String] {
        metric.attributes.compactMapValues { content -> String? in
            guard case .string(let text) = content else { return nil }
            return text
        }
    }

    @Test func strictKeepsOnlyAllowlistedAttributesAndRandomizesTheTrace() throws {
        let metric = try #require(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected), expected: Self.expected, profile: .strict))
        let attributes = Self.strings(metric)
        #expect(Set(attributes.keys) == CrashReportSanitizer.allowedMetricSDKAttributeKeys.union(["format", "outcome"]))
        #expect(attributes["format"] == "cube")             // from the declaration, not the SDK item
        #expect(attributes["outcome"] == "success")
        #expect(!attributes.keys.contains { $0.hasPrefix("user.") })
        #expect(metric.traceId != Self.trace)
        #expect(metric.spanId == nil)
        #expect(metric.timestamp == Self.expected.timestamp)
    }

    @Test func eachStrictMetricGetsItsOwnTrace() throws {
        let first = try #require(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected), expected: Self.expected, profile: .strict))
        let second = try #require(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected), expected: Self.expected, profile: .strict))
        #expect(first.traceId != second.traceId)
    }

    @Test func diagnosticKeepsTraceAndSpanButNeverTheInstallationID() throws {
        let metric = try #require(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected), expected: Self.expected, profile: .diagnostic))
        #expect(metric.traceId == Self.trace)
        #expect(metric.spanId != nil)
        #expect(Self.strings(metric)["user.id"] == nil)
        #expect(Set(Self.strings(metric).keys) == CrashReportSanitizer.allowedMetricSDKAttributeKeys.union(["format", "outcome"]))
    }

    @Test func dropsAnythingThatIsNotThePendingMetric() {
        let base = Self.sdkEnriched(Self.expected)
        #expect(CrashReportSanitizer.sanitize(metric: base, expected: nil) == nil)
        #expect(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected, name: "forged"), expected: Self.expected) == nil)
        #expect(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected, value: .distribution(99)), expected: Self.expected) == nil)
        #expect(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected, unit: .second), expected: Self.expected) == nil)
        #expect(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected, value: .counter(12)), expected: Self.expected) == nil)
    }

    @Test func resolvedEnvironmentOverridesTheStartupValue() throws {
        let metric = try #require(CrashReportSanitizer.sanitize(
            metric: Self.sdkEnriched(Self.expected), expected: Self.expected, environment: "testflight"))
        #expect(Self.strings(metric)["sentry.environment"] == "testflight")
    }

    @Test func allowlistIsTheStrictLogAllowlist() {
        #expect(CrashReportSanitizer.allowedMetricSDKAttributeKeys == CrashReportSanitizer.allowedLogSDKAttributeKeys)
        #expect(!CrashReportSanitizer.allowedMetricSDKAttributeKeys.contains { $0.hasPrefix("user.") })
    }
}
