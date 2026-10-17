import Foundation
import Sentry
import Testing
@testable import ReportsKit

@Suite struct CrashReportSanitizerLogTests {
    /// The attribute set sentry-cocoa 9.24.0's scope applier can produce, plus planted junk.
    static func sdkEnriched(_ expected: ExpectedLog, body: String? = nil) -> SentryLog {
        var attributes: [String: SentryAttribute] = expected.attributes.mapValues { SentryAttribute(string: $0) }
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
            "sentry._internal.replay_is_buffering": "true",
            "sentry.message.template": "opened {0}",
            "sentry.message.parameter.0": "/Users/jane/Client Smith.cube",
            "device.name": "Jane's MacBook Pro",
            "file.path": "/Volumes/Work/x.profile"
        ]
        for (key, value) in sdk { attributes[key] = SentryAttribute(string: value) }
        return SentryLog(level: expected.level, body: body ?? expected.body, attributes: attributes)
    }

    static let errorLog = CrashReporting.makeLog(
        .error, error: NSError(domain: NSCocoaErrorDomain, code: 260), operation: .exportSave,
        describe: TestErrors.describe)

    static func stringValues(_ log: SentryLog) -> [String: String] {
        log.attributes.compactMapValues { $0.value as? String }
    }

    @Test func errorVariantBodyUsesDescribeErrorOnly() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 260,
            userInfo: [NSFilePathErrorKey: "/Users/jane/Client Smith.cube",
                       NSLocalizedDescriptionKey: "jane@example.com secret words"])
        let log = CrashReporting.makeLog(.warning, error: error, operation: .exportSave, describe: TestErrors.describe)
        #expect(log.body == "exportSave NSError code=260")
        #expect(log.level == .warn)
        #expect(log.attributes == [
            "report.op": "exportSave", "report.error": "NSError code=260", "report.source": "reportskit"
        ])
    }

    @Test func messageVariantBodyIsTheStaticMessage() {
        let log = CrashReporting.makeLog(.error, message: "Falling back to software rendering", operation: .deviceStart)
        #expect(log.body == "Falling back to software rendering")
        #expect(log.level == .error)
        #expect(log.attributes == ["report.op": "deviceStart", "report.source": "reportskit"])
    }

    @Test func keepsOnlyAllowlistedAttributes() throws {
        let sanitized = try #require(CrashReportSanitizer.sanitize(log: Self.sdkEnriched(Self.errorLog), expected: Self.errorLog))
        #expect(sanitized.body == "exportSave NSError code=260")
        #expect(Self.stringValues(sanitized) == [
            "report.op": "exportSave",
            "report.error": "NSError code=260",
            "report.source": "reportskit",
            "sentry.sdk.name": "sentry.cocoa",
            "sentry.sdk.version": "9.24.0",
            "sentry.environment": "production",
            "sentry.release": "com.example.MyApp@2.3+417",
            "os.name": "macOS",
            "os.version": "26.0",
            "device.brand": "Apple",
            "device.model": "Mac15,3",
            "device.family": "Mac"
        ])
    }

    @Test func environmentOverrideReplacesTheSDKEnvironmentAttribute() throws {
        let sanitized = try #require(CrashReportSanitizer.sanitize(
            log: Self.sdkEnriched(Self.errorLog), expected: Self.errorLog, environment: "testflight"))
        let values = Self.stringValues(sanitized)
        #expect(values["sentry.environment"] == "testflight")
        #expect(Set(values.keys).isSubset(of: CrashReportSanitizer.allowedLogAttributeKeys))
    }

    @Test func ourAttributesComeFromTheExpectedLogNotTheIncomingOne() throws {
        let incoming = Self.sdkEnriched(Self.errorLog)
        incoming.setAttribute(SentryAttribute(string: "/Users/jane"), forKey: "report.error")
        let sanitized = try #require(CrashReportSanitizer.sanitize(log: incoming, expected: Self.errorLog))
        #expect(Self.stringValues(sanitized)["report.error"] == "NSError code=260")
    }

    @Test func rejectsLogWithoutMarker() {
        let log = Self.sdkEnriched(Self.errorLog)
        log.setAttribute(nil, forKey: "report.source")
        #expect(CrashReportSanitizer.sanitize(log: log, expected: Self.errorLog) == nil)
    }

    @Test func rejectsWrongMarkerValue() {
        let log = Self.sdkEnriched(Self.errorLog)
        log.setAttribute(SentryAttribute(string: "someone-else"), forKey: "report.source")
        #expect(CrashReportSanitizer.sanitize(log: log, expected: Self.errorLog) == nil)
    }

    @Test func rejectsWhenNoLogIsBeingEmitted() {
        #expect(CrashReportSanitizer.sanitize(log: Self.sdkEnriched(Self.errorLog), expected: nil) == nil)
    }

    @Test func rejectsForgedMarkerWithDifferentBody() {
        let forged = Self.sdkEnriched(Self.errorLog, body: "opened /Users/jane/Client Smith.cube")
        #expect(CrashReportSanitizer.sanitize(log: forged, expected: Self.errorLog) == nil)
    }

    @Test func rejectsDifferentLevel() {
        let log = Self.sdkEnriched(Self.errorLog)
        log.level = .info
        #expect(CrashReportSanitizer.sanitize(log: log, expected: Self.errorLog) == nil)
    }

    @Test func pendingLogIsScopedToTheCall() {
        #expect(PendingLog.current == nil)
        let seen = PendingLog.with(Self.errorLog) { PendingLog.current }
        #expect(seen == Self.errorLog)
        #expect(PendingLog.current == nil)
    }

    @Test func pendingLogIsPerThread() {
        final class Result: @unchecked Sendable { var value: ExpectedLog?; var ran = false }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        PendingLog.with(Self.errorLog) {
            // A separate OS thread (DispatchQueue.sync may run on the calling thread).
            let thread = Thread {
                result.value = PendingLog.current
                result.ran = true
                done.signal()
            }
            thread.start()
            done.wait()
        }
        #expect(result.ran)
        #expect(result.value == nil)
    }

    static let forwarded = ExpectedLog(
        level: .error, body: "session start failed: /Users/jane/Client Smith.cube",
        attributes: ["report.source": "app-log", "report.category": "SDI", "report.dropped": "3"],
        timestamp: Date(timeIntervalSince1970: 1_000))

    @Test func strictRejectsForwardedLogsEvenWhenPending() {
        #expect(CrashReportSanitizer.sanitize(log: Self.sdkEnriched(Self.forwarded), expected: Self.forwarded) == nil)
        #expect(CrashReportSanitizer.sanitize(
            log: Self.sdkEnriched(Self.forwarded), expected: Self.forwarded, profile: .strict) == nil)
    }

    @Test func diagnosticKeepsForwardedLogWithCategoryAndInstallationID() throws {
        let sanitized = try #require(CrashReportSanitizer.sanitize(
            log: Self.sdkEnriched(Self.forwarded), expected: Self.forwarded, profile: .diagnostic))
        let values = Self.stringValues(sanitized)
        #expect(sanitized.body == "session start failed: /Users/jane/Client Smith.cube")
        #expect(values["report.source"] == "app-log")
        #expect(values["report.category"] == "SDI")
        #expect(values["report.dropped"] == "3")
        #expect(values["user.id"] == "installation-id-123")
        for key in ["user.name", "user.email", "device.name", "file.path", "sentry.replay_id",
                    "sentry.message.template", "sentry.message.parameter.0"] {
            #expect(values[key] == nil, "kept \(key)")
        }
        #expect(sanitized.timestamp == Date(timeIntervalSince1970: 1_000))
    }

    @Test func strictStripsDiagnosticOnlyAttributesFromReportsKitLogs() throws {
        let expected = ExpectedLog(level: .error, body: "exportSave NSError code=260", attributes: [
            "report.source": "reportskit", "report.op": "exportSave", "report.error": "NSError code=260",
            "report.error.detail": "/Users/jane/x", "report.category": "SDI"
        ])
        let sanitized = try #require(CrashReportSanitizer.sanitize(log: Self.sdkEnriched(expected), expected: expected))
        let keys = Set(Self.stringValues(sanitized).keys)
        #expect(keys.isSubset(of: CrashReportSanitizer.allowedLogAttributeKeys))
        #expect(!keys.contains("report.error.detail"))
        #expect(!keys.contains("user.id"))
    }

    @Test func diagnosticKeepsErrorDetailOnReportsKitLogs() throws {
        let expected = ExpectedLog(level: .error, body: "exportSave NSError code=260", attributes: [
            "report.source": "reportskit", "report.op": "exportSave", "report.error": "NSError code=260",
            "report.error.detail": "/Users/jane/x"
        ])
        let sanitized = try #require(CrashReportSanitizer.sanitize(
            log: Self.sdkEnriched(expected), expected: expected, profile: .diagnostic))
        #expect(Self.stringValues(sanitized)["report.error.detail"] == "/Users/jane/x")
    }
}
