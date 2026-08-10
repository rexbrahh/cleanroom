import CleanroomCore
import Foundation
import Testing

@Suite("Preflight freshness")
struct PreflightFreshnessTests {
    @Test("stale or incomplete probe evidence never reports Ready")
    func readinessFailsClosed() {
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let fresh = PreflightProbeEvidence(
            id: "input",
            name: "Input",
            state: .succeeded,
            checkedAt: checkedAt,
            lastSucceededAt: checkedAt
        )
        let incomplete = PreflightProbeEvidence(
            id: "network",
            name: "Network",
            state: .incomplete,
            checkedAt: checkedAt,
            lastSucceededAt: nil
        )

        let freshReport = PreflightReport(generatedAt: checkedAt, findings: [], probes: [fresh])
        #expect(freshReport.isReady(at: checkedAt.addingTimeInterval(119)))
        #expect(!freshReport.isReady(at: checkedAt.addingTimeInterval(121)))
        #expect(
            !PreflightReport(generatedAt: checkedAt, findings: [], probes: [fresh, incomplete])
                .isReady(at: checkedAt)
        )
        #expect(!PreflightReport(generatedAt: checkedAt, findings: []).isReady(at: checkedAt))
        #expect(fresh.ageSeconds == 0)
        #expect(fresh.age(at: checkedAt.addingTimeInterval(30)) == 30)
    }
}
