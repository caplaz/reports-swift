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
}
