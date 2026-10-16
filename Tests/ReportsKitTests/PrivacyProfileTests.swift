import Testing
@testable import ReportsKit

@Suite struct PrivacyProfileTests {
    @Test func rawValuesAreStable() {
        #expect(CrashReporting.PrivacyProfile.allCases.map(\.rawValue) == ["strict", "diagnostic"])
    }

    @Test func mostPrivateIsDiagnosticOnlyWhenBothAre() {
        typealias P = CrashReporting.PrivacyProfile
        #expect(P.mostPrivate(.diagnostic, .diagnostic) == .diagnostic)
        #expect(P.mostPrivate(.diagnostic, .strict) == .strict)
        #expect(P.mostPrivate(.strict, .diagnostic) == .strict)
        #expect(P.mostPrivate(.strict, .strict) == .strict)
    }
}
