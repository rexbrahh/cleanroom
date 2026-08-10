import Foundation
import Testing

@testable import CleanroomCore
@testable import CleanroomProtocol

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

    @Test("v1 snapshots without provenance remain readable")
    func legacySnapshotDecodes() throws {
        let data = Data(
            """
            {
              "activeServiceLabels":[],
              "activeApplicationBundleIdentifiers":["com.example.app"],
              "activeProcessNames":["example-process"],
              "preferences":[]
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(SystemSnapshot.self, from: data)

        #expect(snapshot.applications.count == 1)
        #expect(snapshot.applications.first?.bundleIdentifier == "com.example.app")
        #expect(snapshot.applications.first?.processIdentifiers.isEmpty == true)
        #expect(snapshot.processes == [StoredProcess(executableName: "example-process", processIdentifiers: [])])
    }

    @Test("agent responses without build identity remain readable")
    func legacyAgentResponseDecodes() throws {
        let identifier = UUID()
        let data = Data(
            """
            {"requestIdentifier":"\(identifier.uuidString)","payload":{"requestInProgress":{}}}
            """.utf8
        )

        let response = try AgentCodec.decode(AgentResponse.self, from: data)

        #expect(response.requestIdentifier == identifier)
        #expect(response.payload == .requestInProgress)
        #expect(response.agentBuild == nil)
    }
}
