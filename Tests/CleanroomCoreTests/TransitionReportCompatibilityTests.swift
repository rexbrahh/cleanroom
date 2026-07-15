import Foundation
import Testing

@testable import CleanroomCore

@Suite("Transition event compatibility")
struct TransitionReportCompatibilityTests {
    @Test("v1 events without timestamps remain readable")
    func legacyEventDecodes() throws {
        let data = Data(
            """
            {"phase":"idle","message":"legacy event","results":[],"preflight":null}
            """.utf8
        )

        let report = try JSONDecoder().decode(TransitionReport.self, from: data)

        #expect(report.phase == .idle)
        #expect(report.message == "legacy event")
        #expect(report.occurredAt == nil)
    }
}
