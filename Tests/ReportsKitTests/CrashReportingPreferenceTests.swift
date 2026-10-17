import Foundation
import Testing
@testable import ReportsKit

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

    @Test func detailedDiagnosticsDefaultsToOff() {
        #expect(!CrashReportingPreference.isDetailedDiagnosticsEnabled(in: freshDefaults()))
    }

    @Test func persistsDetailedDiagnostics() {
        let defaults = freshDefaults()
        CrashReportingPreference.setDetailedDiagnostics(true, in: defaults)
        #expect(CrashReportingPreference.isDetailedDiagnosticsEnabled(in: defaults))
        #expect(defaults.object(forKey: "crashReportingDetailedDiagnostics") as? Bool == true)
    }

    @Test func lastProfileDefaultsToStrictAndRoundTrips() {
        let defaults = freshDefaults()
        #expect(CrashReportingPreference.lastProfile(in: defaults) == .strict)
        CrashReportingPreference.setLastProfile(.diagnostic, in: defaults)
        #expect(CrashReportingPreference.lastProfile(in: defaults) == .diagnostic)
        defaults.set("garbage", forKey: CrashReportingPreference.lastProfileKey)
        #expect(CrashReportingPreference.lastProfile(in: defaults) == .strict)
    }

    @Test func pendingPurgeDefaultsToNoneAndRoundTrips() {
        let defaults = freshDefaults()
        #expect(!CrashReportingPreference.hasPendingPurge(in: defaults))
        CrashReportingPreference.setPendingPurge(true, in: defaults)
        #expect(CrashReportingPreference.hasPendingPurge(in: defaults))
        CrashReportingPreference.setPendingPurge(false, in: defaults)
        #expect(!CrashReportingPreference.hasPendingPurge(in: defaults))
        #expect(defaults.object(forKey: CrashReportingPreference.pendingPurgeKey) == nil)
    }

    @Test func pendingMetricSweepDefaultsToNoneAndRoundTrips() {
        let defaults = freshDefaults()
        #expect(!CrashReportingPreference.hasPendingMetricSweep(in: defaults))
        CrashReportingPreference.setPendingMetricSweep(true, in: defaults)
        #expect(CrashReportingPreference.hasPendingMetricSweep(in: defaults))
        CrashReportingPreference.setPendingMetricSweep(false, in: defaults)
        #expect(defaults.object(forKey: CrashReportingPreference.pendingMetricSweepKey) == nil)
    }
}
