import Foundation
import Sentry
import Testing
@testable import PatternSpaceCrashReporting

@Suite struct CrashReportSanitizerSpanTests {
    @Test func descriptionKeptOnlyForAllowlistedOps() {
        #expect(CrashReportSanitizer.keepsDescription(operation: "app.start.cold"))
        #expect(CrashReportSanitizer.keepsDescription(operation: "ui.load"))
        #expect(CrashReportSanitizer.keepsDescription(operation: "ui.load.full_display"))
        #expect(!CrashReportSanitizer.keepsDescription(operation: "file.read"))
        #expect(!CrashReportSanitizer.keepsDescription(operation: "http.client"))
    }

    @Test func breadcrumbKeepsOnlyCodeIdentifiers() throws {
        let crumb = Breadcrumb(level: .info, category: "ui.lifecycle")
        crumb.type = "navigation"
        crumb.message = "jane"
        crumb.setData(value: "SettingsRoot", key: "screen")
        crumb.setData(value: "viewDidAppear", key: "state")
        crumb.setData(value: "/Users/jane", key: "to")
        let result = try #require(CrashReportSanitizer.sanitize(crumb))
        #expect(result.message == nil)
        #expect(result.category == "ui.lifecycle")
        #expect(result.type == "navigation")
        #expect(result.data?.keys.sorted() == ["screen", "state"])
    }

    @Test func lastPathComponentHandlesBareNames() {
        #expect(CrashReportSanitizer.lastPathComponent("libswiftCore.dylib") == "libswiftCore.dylib")
        #expect(CrashReportSanitizer.lastPathComponent("/usr/lib/libobjc.A.dylib") == "libobjc.A.dylib")
    }
}
