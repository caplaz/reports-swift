import Foundation
import Testing
@testable import ReportsKit

@Suite struct ConsentGateTests {
    private let session = URLSession(configuration: .ephemeral)
    private func makeTask() -> URLSessionTask {
        session.dataTask(with: URL(string: "https://reports.example.invalid/api/1/envelope/")!)
    }

    @Test func refusesAdmissionWhileDisabled() {
        let gate = ConsentGate()
        var built = false
        let task = gate.admit { built = true; return makeTask() }
        #expect(task == nil)
        #expect(!built)
    }

    @Test func admitsAndTracksWhileEnabled() {
        let gate = ConsentGate()
        gate.setEnabled(true)
        let task = gate.admit { makeTask() }
        #expect(task != nil)
        #expect(gate.admittedCount == 1)
        gate.finished(task!)
        #expect(gate.admittedCount == 0)
    }

    @Test func disablingCancelsAdmittedTasks() {
        let gate = ConsentGate()
        gate.setEnabled(true)
        let task = gate.admit { makeTask() }!
        gate.setEnabled(false)
        #expect(task.state == .canceling || task.state == .completed)
        #expect(gate.admittedCount == 0)
        #expect(gate.admit { makeTask() } == nil)
    }

    @Test func conditionalAdmissionChecksValidityUnderTheGateLock() {
        let gate = ConsentGate()
        var checked = false
        // Closed is decided first; validity isn't even evaluated.
        guard case .closed = gate.admit(while: { checked = true; return true }, { makeTask() }) else {
            Issue.record("expected .closed")
            return
        }
        #expect(!checked)
        gate.setEnabled(true)
        var built = false
        guard case .stale = gate.admit(while: { false }, { built = true; return makeTask() }) else {
            Issue.record("expected .stale")
            return
        }
        #expect(!built)
        #expect(gate.admittedCount == 0)
        guard case .admitted(let task) = gate.admit(while: { true }, { makeTask() }) else {
            Issue.record("expected .admitted")
            return
        }
        #expect(gate.admittedCount == 1)
        gate.setEnabled(false)                              // admitted tasks are revoked as before
        #expect(task.state == .canceling || task.state == .completed)
        #expect(gate.admittedCount == 0)
    }
}
