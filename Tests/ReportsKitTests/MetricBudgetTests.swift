import Foundation
import Testing
@testable import ReportsKit

@Suite struct MetricBudgetTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    @Test func perMinuteCapDropsAndReportsTheCountOnceAfterTheWindow() {
        let clock = Clock()
        let budget = MetricBudget(perMinute: 2, perProcess: 100, now: { clock.now })
        #expect(budget.admit() == 0)
        #expect(budget.admit() == 0)
        #expect(budget.admit() == nil)
        #expect(budget.admit() == nil)
        clock.advance(59)
        #expect(budget.admit() == nil)
        clock.advance(1)
        #expect(budget.admit() == 3)
        #expect(budget.admit() == 0)
    }

    @Test func processCapIsFinal() {
        let clock = Clock()
        let budget = MetricBudget(perMinute: 10, perProcess: 3, now: { clock.now })
        for _ in 0..<3 { #expect(budget.admit() == 0) }
        #expect(budget.admit() == nil)
        clock.advance(3_600)
        #expect(budget.admit() == nil)
    }

    @Test func defaultsMatchTheSpec() {
        #expect(MetricBudget.defaultPerMinute == 60)
        #expect(MetricBudget.defaultPerProcess == 3_000)
    }
}
