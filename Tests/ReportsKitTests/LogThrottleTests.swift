import Foundation
import Testing
@testable import ReportsKit

@Suite struct LogThrottleTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    static func key(
        _ level: CrashReporting.LogLevel = .error, _ operation: CrashReporting.Operation = .exportSave,
        _ body: String = "exportSave NSError code=1"
    ) -> LogThrottle.Key {
        LogThrottle.Key(level: level, operation: operation, body: body)
    }

    @Test func admitsFirstAndDropsRepeatsWithinTheWindow() {
        let clock = Clock()
        let throttle = LogThrottle(now: { clock.now })
        #expect(throttle.admit(Self.key()))
        #expect(!throttle.admit(Self.key()))
        clock.advance(59.9)
        #expect(!throttle.admit(Self.key()))
    }

    @Test func admitsAgainAfterTheWindow() {
        let clock = Clock()
        let throttle = LogThrottle(now: { clock.now })
        #expect(throttle.admit(Self.key()))
        clock.advance(60)
        #expect(throttle.admit(Self.key()))
        clock.advance(30)
        #expect(!throttle.admit(Self.key()))
    }

    @Test func windowIsMeasuredFromTheLastAdmittedLogNotTheLastAttempt() {
        let clock = Clock()
        let throttle = LogThrottle(now: { clock.now })
        #expect(throttle.admit(Self.key()))
        for _ in 0..<5 {
            clock.advance(11)
            _ = throttle.admit(Self.key())
        }
        clock.advance(5)   // 60 s after the admitted one
        #expect(throttle.admit(Self.key()))
    }

    @Test func keysDifferByLevelOperationAndBody() {
        let throttle = LogThrottle(now: { 0 })
        #expect(throttle.admit(Self.key(.error, .exportSave, "a")))
        #expect(throttle.admit(Self.key(.warning, .exportSave, "a")))
        #expect(throttle.admit(Self.key(.error, .deviceStart, "a")))
        #expect(throttle.admit(Self.key(.error, .exportSave, "b")))
        #expect(!throttle.admit(Self.key(.error, .exportSave, "a")))
    }

    @Test func defaultWindowIsSixtySeconds() {
        #expect(LogThrottle.defaultInterval == 60)
    }

    @Test func prunesExpiredKeysSoMemoryStaysBounded() {
        let clock = Clock()
        let throttle = LogThrottle(now: { clock.now })
        for index in 0..<(LogThrottle.pruneThreshold + 10) {
            #expect(throttle.admit(Self.key(.error, .exportSave, "\(index)")))
        }
        clock.advance(61)
        #expect(throttle.admit(Self.key(.error, .exportSave, "fresh")))
        #expect(throttle.trackedKeyCount == 1)
    }

    @Test func isSafeUnderConcurrentUse() async {
        let throttle = LogThrottle(now: { 0 })
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 { group.addTask { throttle.admit(Self.key()) } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(admitted == 1)
    }
}
