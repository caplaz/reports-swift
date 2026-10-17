import Testing
@testable import ReportsKit

@Suite struct MetricTests {
    typealias Metric = CrashReporting.Metric

    @Test func namesAreLowercaseDottedIdentifiers() {
        #expect(Metric.isValidName("app.launch.duration"))
        #expect(Metric.isValidName("decklink.frames_late"))
        #expect(Metric.isValidName("a"))
        #expect(!Metric.isValidName(""))
        #expect(!Metric.isValidName("App.launch"))
        #expect(!Metric.isValidName("1app"))
        #expect(!Metric.isValidName("a b"))
        #expect(!Metric.isValidName("a/b"))
        #expect(!Metric.isValidName(String(repeating: "a", count: 65)))
        #expect(Metric.isValidName(String(repeating: "a", count: 64)))
    }

    @Test func keysMayNotUseReservedPrefixes() {
        #expect(Metric.isValidKey("format"))
        #expect(Metric.isValidKey("outcome"))
        for key in ["user.id", "sentry.release", "os.name", "device.model", "report.op"] {
            #expect(!Metric.isValidKey(key), "\(key)")
        }
    }

    @Test func valuesAreShortIdentifiers() {
        for value in ["hd1080p2398", "cube3D", "le17", "not_admitted", "a-b.c", "other"] {
            #expect(Metric.isValidValue(value), "\(value)")
        }
        for value in ["", "/Users/jane", "a b", "é", "jane@example.com", String(repeating: "a", count: 65)] {
            #expect(!Metric.isValidValue(value), "\(value)")
        }
        #expect(Metric.outcomes.allSatisfy(Metric.isValidValue))
    }

    @Test func filteringDropsUndeclaredKeysAndMapsUndeclaredValuesToOther() {
        let metric = Metric(
            "test.metric", kind: .distribution, unit: .millisecond,
            attributes: ["format": ["cube", "3dl"], "outcome": Metric.outcomes])
        #expect(metric.filtered(["format": "cube", "outcome": "success"]) == ["format": "cube", "outcome": "success"])
        #expect(metric.filtered(["format": "/Users/jane/Client Smith.cube", "path": "/Users/jane"]) == ["format": "other"])
        #expect(metric.filtered([:]) == [:])
    }

    @Test func declarationKeepsItsFields() {
        let metric = Metric("test.count", kind: .counter, attributes: ["level": ["warning", "critical"]])
        #expect(metric.name == "test.count")
        #expect(metric.kind == .counter)
        #expect(metric.unit == .none)
        #expect(metric.attributes == ["level": ["warning", "critical"]])
    }
}
