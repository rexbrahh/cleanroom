import CleanroomCore
import Testing

@Suite("Deterministic session simulator")
struct DeterministicSessionSimulatorTests {
    @Test("replays triggers, time, results, timeout, restart, and corruption without a desktop controller")
    func completeScenarioIsRepeatable() async {
        let scenario = SimulationScenario(events: [
            .trigger(.running),
            .systemResult(operation: .verify, outcome: .succeeded),
            .command(.reconcile),
            .trigger(.stopped),
            .command(.reconcile),
            .advanceTime(seconds: 6),
            .timeout(.restore),
            .command(.reconcile),
            .restart,
            .corruptJournal,
            .command(.restore),
        ])

        let first = await DeterministicSessionSimulator(scenario: scenario).run()
        let second = await DeterministicSessionSimulator(scenario: scenario).run()

        #expect(first == second)
        #expect(first[2].phase == .active)
        #expect(first[2].journalPresent)
        #expect(first[7].phase == .degraded)
        #expect(first[7].results.contains(where: { $0.detail == "simulated timeout" }))
        #expect(first[8].message.contains("engine restarted"))
        #expect(first[10].phase == .degraded)
        #expect(first[10].message.contains("simulated corruption"))
        #expect(first[10].journalPresent)
    }
}
