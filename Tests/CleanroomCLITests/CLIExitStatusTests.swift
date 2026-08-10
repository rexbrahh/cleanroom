import CleanroomCore
import CleanroomProtocol
import Foundation
import Testing

@testable import CleanroomCLI

@Suite("CLI machine-readable exit status")
struct CLIExitStatusTests {
    @Test("degraded status and critical preflight have distinct exit codes")
    func payloadExitCodes() {
        let status = CleanroomStatus(
            phase: .degraded,
            trigger: TriggerProbe(state: .unknown, detail: "test"),
            journal: nil,
            lastMessage: "degraded",
            lastResults: [],
            preflight: nil,
            agentStartedAt: nil,
            heartbeatAt: nil
        )
        let preflight = PreflightReport(
            findings: [
                PreflightFinding(
                    id: "critical",
                    severity: .critical,
                    category: "test",
                    summary: "critical",
                    detail: "test"
                )
            ]
        )

        #expect(CLIExitStatus.failure(for: .status(status)) == .degraded)
        #expect(CLIExitStatus.failure(for: .preflight(preflight)) == .criticalPreflight)
        #expect(CLIExitStatus.failure(for: .requestInProgress) == .requestInProgress)
    }

    @Test("protocol and reachability failures have distinct exit codes")
    func errorExitCodes() {
        #expect(
            CLIExitStatus.failure(for: AgentProtocolError.requestMismatch) == .protocolFailure
        )
        #expect(CLIExitStatus.failure(for: AgentProtocolError.timedOut) == .unreachable)
        #expect(
            CLIExitStatus.failure(
                for: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
            ) == .unreachable
        )
    }

    @Test("doctor requires all three checks and watch output is one bounded line")
    func doctorAndWatchContracts() {
        let checks = [
            DoctorCheck(id: "registration", passed: true, detail: "ok"),
            DoctorCheck(id: "protocol", passed: true, detail: "ok"),
            DoctorCheck(id: "health", passed: true, detail: "ok"),
        ]
        #expect(DoctorReport(generatedAt: .distantPast, checks: checks).passed)
        #expect(
            !DoctorReport(
                generatedAt: .distantPast,
                checks: checks.dropLast() + [DoctorCheck(id: "health", passed: false, detail: "bad")]
            ).passed)

        let status = CleanroomStatus(
            phase: .active,
            trigger: TriggerProbe(state: .running),
            journal: nil,
            lastMessage: "active",
            lastResults: [],
            preflight: nil,
            heartbeatAt: Date(timeIntervalSince1970: 10)
        )
        let line = WatchStatusLine(status: status, sampledAt: Date(timeIntervalSince1970: 20)).description
        #expect(line.split(separator: "\n").count == 1)
        #expect(line.contains("phase=active"))
        #expect(line.contains("trigger=running"))
    }
}
