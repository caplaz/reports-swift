import Foundation
import Testing
@testable import PatternSpaceCrashReporting

@Suite struct CrashReportingPreferenceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "CrashReportingPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToEnabled() {
        #expect(CrashReportingPreference.isEnabled(in: freshDefaults()))
    }

    @Test func persistsOptOut() {
        let defaults = freshDefaults()
        CrashReportingPreference.set(false, in: defaults)
        #expect(!CrashReportingPreference.isEnabled(in: defaults))
        #expect(defaults.object(forKey: "crashReportingEnabled") as? Bool == false)
    }
}
