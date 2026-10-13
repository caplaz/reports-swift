import Foundation
import Testing
@testable import PatternSpaceCrashReporting

@Suite struct DataInputStreamTests {
    @Test func readErrorDoesNotForwardATruncatedBody() {
        let stream = FailingAfterFirstReadInputStream()
        #expect(Data(reading: stream) == nil)
    }

    @Test func cleanEndOfStreamStillReturnsTheFullBody() {
        let stream = InputStream(data: Data("envelope".utf8))
        #expect(Data(reading: stream) == Data("envelope".utf8))
    }
}
