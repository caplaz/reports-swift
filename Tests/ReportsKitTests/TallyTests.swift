import Foundation
import Testing
@testable import ReportsKit

@Suite struct TallyTests {
    static let metric = CrashReporting.Metric("test.tally", kind: .counter)

    final class Recorder: @unchecked Sendable {
        let clock = Locked<TimeInterval>(1_000)
        /// The consent epoch the tally sees; `nil` = metrics can't be recorded (reporting off).
        let consent = Locked<UInt64?>(1)
        let emitted = Locked<[UInt]>([])
        let epochs = Locked<[UInt64]>([])
        func tally(interval: TimeInterval = 60) -> CrashReporting.Tally {
            CrashReporting.Tally(Self.metric, attributes: [:], interval: interval,
                                 now: { [clock] in clock.value },
                                 consent: { [consent] in consent.value },
                                 emit: { [emitted, epochs] value, epoch in
                                     emitted.value.append(value)
                                     epochs.value.append(epoch)
                                 })
        }
        static let metric = TallyTests.metric
    }

    @Test func addsUpAndEmitsOncePerInterval() {
        let recorder = Recorder()
        let tally = recorder.tally()
        tally.add()
        tally.add(2)
        recorder.clock.value += 59
        tally.add()
        #expect(recorder.emitted.value.isEmpty)
        recorder.clock.value += 1
        tally.add()
        #expect(recorder.emitted.value == [5])
        tally.add()
        #expect(recorder.emitted.value == [5])
        tally.flush()
        #expect(recorder.emitted.value == [5, 1])
        #expect(recorder.epochs.value == [1, 1])
        tally.flush()
        #expect(recorder.emitted.value == [5, 1])
    }

    @Test func flushWithNothingPendingEmitsNothing() {
        let recorder = Recorder()
        recorder.tally().flush()
        #expect(recorder.emitted.value.isEmpty)
    }

    @Test func saturatesInsteadOfOverflowing() {
        let recorder = Recorder()
        let tally = recorder.tally()
        tally.add(UInt.max)
        tally.add(1)
        tally.flush()
        #expect(recorder.emitted.value == [UInt.max])
    }

    @Test func concurrentAddsAreNotLost() async {
        let recorder = Recorder()
        let tally = recorder.tally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<1_000 { tally.add() } } }
        }
        tally.flush()
        #expect(recorder.emitted.value == [8_000])
    }

    /// Review finding (tallies across consent changes): accumulate, opt out, add while off,
    /// re-enable, flush. Nothing from before or during the opt-out is emitted; adds after the
    /// re-enable are, tagged with the new epoch.
    @Test func totalsFromBeforeOrDuringAnOptOutAreNeverEmitted() {
        let recorder = Recorder()
        let tally = recorder.tally()
        tally.add(3)                       // epoch 1
        recorder.consent.value = nil       // opt-out
        tally.add(5)                       // rejected while off
        recorder.consent.value = 2         // re-enabled: a new epoch
        tally.flush()
        #expect(recorder.emitted.value.isEmpty)
        tally.add(2)
        tally.flush()
        #expect(recorder.emitted.value == [2])
        #expect(recorder.epochs.value == [2])
    }

    @Test func theFirstAddOfANewEpochDiscardsTheOldTotalAndOpensAFreshWindow() {
        let recorder = Recorder()
        let tally = recorder.tally()
        tally.add(3)                       // epoch 1, window opens at 1_000
        recorder.clock.value += 30
        recorder.consent.value = 2         // opted out and back in
        tally.add()                        // discards the 3; window reopens at 1_030
        recorder.clock.value += 59
        tally.add()
        #expect(recorder.emitted.value.isEmpty)
        recorder.clock.value += 1
        tally.add()
        #expect(recorder.emitted.value == [3])
        #expect(recorder.epochs.value == [2])
    }

    @Test func addsWhileOffNeverCount() {
        let recorder = Recorder()
        recorder.consent.value = nil
        let tally = recorder.tally()
        tally.add(7)
        recorder.consent.value = 1
        tally.flush()
        #expect(recorder.emitted.value.isEmpty)
    }
}
