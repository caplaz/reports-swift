import Foundation
import Testing
@testable import ReportsKit

@Suite struct ForwardBudgetTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    static func key(_ body: String, category: String = "SDI") -> ForwardBudget.Key {
        ForwardBudget.Key(level: .error, category: category, body: body)
    }

    @Test func repeatsWithinTheRepeatIntervalAreDroppedAndCountedOnce() {
        let clock = Clock()
        let budget = ForwardBudget(now: { clock.now })
        #expect(budget.admit(Self.key("a")) == 0)
        #expect(budget.admit(Self.key("a")) == nil)
        clock.advance(9)
        #expect(budget.admit(Self.key("a")) == nil)
        clock.advance(1)   // exactly repeatInterval after admission (whole seconds: no FP drift)
        #expect(budget.admit(Self.key("a")) == 2)
        #expect(budget.admit(Self.key("b")) == 0)
    }

    @Test func sameBodyInAnotherCategoryIsNotARepeat() {
        let budget = ForwardBudget(now: { 0 })
        #expect(budget.admit(Self.key("a", category: "SDI")) == 0)
        #expect(budget.admit(Self.key("a", category: "LUT")) == 0)
    }

    @Test func perMinuteCapResetsAfterTheWindow() {
        let clock = Clock()
        let budget = ForwardBudget(perMinute: 3, now: { clock.now })
        for body in ["a", "b", "c"] { #expect(budget.admit(Self.key(body)) == 0) }
        #expect(budget.admit(Self.key("d")) == nil)
        clock.advance(60)
        #expect(budget.admit(Self.key("e")) == 1)
    }

    @Test func perProcessCapIsFinal() {
        let clock = Clock()
        let budget = ForwardBudget(perMinute: 100, perProcess: 2, now: { clock.now })
        #expect(budget.admit(Self.key("a")) == 0)
        #expect(budget.admit(Self.key("b")) == 0)
        clock.advance(3_600)
        #expect(budget.admit(Self.key("c")) == nil)
    }

    @Test func repeatKeysArePruned() {
        let clock = Clock()
        let budget = ForwardBudget(perMinute: 10_000, perProcess: 10_000, now: { clock.now })
        for index in 0...ForwardBudget.pruneThreshold { _ = budget.admit(Self.key("\(index)")) }
        clock.advance(ForwardBudget.repeatInterval)
        _ = budget.admit(Self.key("fresh"))
        #expect(budget.trackedKeyCount <= ForwardBudget.pruneThreshold)
    }

    @Test func bodiesAreTruncated() {
        #expect(ForwardBudget.truncated("short") == "short")
        let long = ForwardBudget.truncated(String(repeating: "x", count: 5_000))
        #expect(long.count == ForwardBudget.maxBodyLength + 1)
        #expect(long.hasSuffix("…"))
    }
}
