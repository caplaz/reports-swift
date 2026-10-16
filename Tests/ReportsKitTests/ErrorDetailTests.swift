import Foundation
import Testing
@testable import ReportsKit

@Suite struct ErrorDetailTests {
    private enum PayloadError: Error { case unreadable(path: String) }

    @Test func nsErrorIncludesDescriptionFileUserInfoAndUnderlyingChain() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 2,
                                 userInfo: [NSFilePathErrorKey: "/Users/jane/underlying.cube"])
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSFilePathErrorKey: "/Users/jane/Documents/Client Smith.cube",
            NSLocalizedDescriptionKey: "The file couldn't be saved.",
            NSUnderlyingErrorKey: underlying
        ])
        let text = ErrorDetail.text(for: error)
        #expect(text.hasPrefix("NSCocoaErrorDomain 4: The file couldn't be saved."))
        #expect(text.contains("NSFilePath: /Users/jane/Documents/Client Smith.cube"))
        #expect(text.contains("caused by: NSPOSIXErrorDomain 2:"))
        #expect(text.contains("/Users/jane/underlying.cube"))
    }

    @Test func swiftErrorIncludesAssociatedValues() {
        let text = ErrorDetail.text(for: PayloadError.unreadable(path: "/Volumes/Work/x.profile"))
        #expect(text.contains("unreadable(path: \"/Volumes/Work/x.profile\")"))
    }

    @Test func underlyingChainIsBounded() {
        var error = NSError(domain: "d", code: 0)
        for code in 1...10 { error = NSError(domain: "d", code: code, userInfo: [NSUnderlyingErrorKey: error]) }
        let text = ErrorDetail.text(for: error)
        #expect(text.components(separatedBy: "caused by:").count - 1 == ErrorDetail.maxDepth - 1)
    }

    @Test func longTextIsTruncated() {
        let error = NSError(domain: "d", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 10_000)])
        let text = ErrorDetail.text(for: error)
        #expect(text.count == ErrorDetail.maxLength + 1)
        #expect(text.hasSuffix("…"))
    }
}
