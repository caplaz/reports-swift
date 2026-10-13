import Foundation
import Sentry
import Testing
@testable import PatternSpaceCrashReporting

@Suite struct CrashReportSanitizerEventTests {
    static let planted = [
        "jane", "Jane", "Client Smith", "jane@example.com", "secret words",
        "/Users/", "/Volumes/", "Containers/com.caplaz", "file%3A", "file://"
    ]

    static func json(_ event: Event) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: event.serialize(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func makeCrashEvent() -> Event {
        let event = Event(level: .fatal)
        let exception = Exception(
            value: "*** -[NSURL initFileURLWithPath:]: /Users/jane/Documents/Client Smith.cube jane@example.com secret words",
            type: "NSInvalidArgumentException")
        let mechanism = Mechanism(type: "nsexception")
        mechanism.desc = "file:///Volumes/Work/Client%20Smith"
        mechanism.data = ["path": "/Users/jane/x.icc"]
        mechanism.helpLink = "file:///Users/jane"
        exception.mechanism = mechanism

        let appPath = "/Users/jane/Applications/PatternSpace.app/Contents/MacOS/PatternSpace"
        let frame = Frame()
        frame.function = "LUTChainSession.exportICC(to:isPro:)"
        frame.instructionAddress = "0x0000000100001234"
        frame.package = appPath
        frame.fileName = "/Users/jane/src/LUTChainSession.swift"
        frame.contextLine = "let secret words = jane"
        frame.preContext = ["jane"]
        frame.postContext = ["jane"]
        frame.vars = ["path": "/Users/jane/x"]
        frame.inApp = NSNumber(value: true)
        let stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        exception.stacktrace = stacktrace
        event.exceptions = [exception]

        let thread = SentryThread(threadId: 0)
        thread.name = "com.apple.main-thread"
        thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.threads = [thread]

        let image = DebugMeta()
        image.type = "macho"
        image.debugID = "B5E9C1D2-0000-0000-0000-000000000001"
        image.imageAddress = "0x0000000100000000"
        image.imageSize = 4096
        image.codeFile = appPath
        let containerImage = DebugMeta()
        containerImage.codeFile = "/private/var/containers/Bundle/Application/1A2B3C4D-5E6F/PatternSpaceIOS.app/PatternSpaceIOS"
        event.debugMeta = [image, containerImage]

        event.user = User(userId: "installation-id-123")
        event.extra = ["path": "/Users/jane/x.cube"]
        event.tags = ["ps.op": "lutExportSave", "device": "Jane's Mac"]
        event.serverName = "Janes-MacBook-Pro.local"
        event.context = [
            "device": ["model": "Mac15,3", "arch": "arm64", "name": "Jane's MacBook Pro", "locale": "en_US"],
            "os": ["name": "macOS", "version": "26.0", "build": "25A100", "kernel_version": "Darwin jane"],
            "app": ["app_version": "2.3", "app_build": "417", "device_app_hash": "abcdef", "app_identifier": "com.caplaz.PatternSpace"],
            "culture": ["locale": "en_US", "timezone": "Europe/Rome"],
            "custom": ["path": "/Users/jane"]
        ]
        let crumb = Breadcrumb(level: .info, category: "ui.lifecycle")
        crumb.message = "opened /Users/jane/Client Smith.cube"
        crumb.setData(value: "LUTToolsWindow", key: "screen")
        crumb.setData(value: "/Users/jane/x", key: "path")
        event.breadcrumbs = [crumb]
        event.message = SentryMessage(formatted: "jane@example.com secret words")
        event.error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSFilePathErrorKey: "/Users/jane/x"])
        return event
    }

    @Test func removesEveryPlantedString() throws {
        let output = try Self.json(CrashReportSanitizer.sanitize(Self.makeCrashEvent()))
        for needle in Self.planted {
            #expect(!output.contains(needle), "leaked: \(needle)")
        }
    }

    @Test func keepsWhatSymbolicationAndTriageNeed() throws {
        let event = CrashReportSanitizer.sanitize(Self.makeCrashEvent())
        let output = try Self.json(event)
        #expect(event.exceptions?.first?.type == "NSInvalidArgumentException")
        #expect(event.exceptions?.first?.value == "<redacted>")
        #expect(event.exceptions?.first?.mechanism?.type == "nsexception")
        let frame = try #require(event.threads?.first?.stacktrace?.frames.first)
        #expect(frame.function == "LUTChainSession.exportICC(to:isPro:)")
        #expect(frame.instructionAddress == "0x0000000100001234")
        #expect(frame.package == "PatternSpace")
        #expect(frame.fileName == nil)
        #expect(event.debugMeta?.map(\DebugMeta.codeFile) == ["PatternSpace", "PatternSpaceIOS"])
        #expect(event.debugMeta?.first?.debugID == "B5E9C1D2-0000-0000-0000-000000000001")
        #expect(output.contains("Mac15,3"))
        #expect(output.contains("com.apple.main-thread"))
        #expect(event.tags == ["ps.op": "lutExportSave"])
    }

    @Test func dropsIdentifiersAndUnlistedContexts() {
        let event = CrashReportSanitizer.sanitize(Self.makeCrashEvent())
        #expect(event.user == nil)
        #expect(event.extra == nil)
        #expect(event.message == nil)
        #expect(event.error == nil)
        #expect(event.serverName == nil)
        #expect(event.context?["culture"] == nil)
        #expect(event.context?["custom"] == nil)
        #expect(event.context?["app"]?["device_app_hash"] == nil)
        #expect(event.context?["device"]?["name"] == nil)
        #expect(event.context?["os"]?["kernel_version"] == nil)
        #expect(event.breadcrumbs?.first?.message == nil)
        #expect(event.breadcrumbs?.first?.data?.keys.sorted() == ["screen"])
    }
}
