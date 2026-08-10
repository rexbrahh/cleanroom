import CleanroomCore
import Foundation
import Testing

@Suite("Support bundle redaction")
struct SupportBundleRedactionTests {
    @Test("bounded evidence omits every declared sensitive field")
    func sensitiveValuesAreAbsent() throws {
        let secret = "SECRET-USER-DATA"
        let result = ActionResult(
            action: "inspect",
            target: secret,
            outcome: .warning,
            detail: secret
        )
        let journal = RecoveryJournal(
            trigger: TriggerProcess(
                processIdentifier: 42,
                bundleIdentifier: secret,
                executableURL: URL(fileURLWithPath: "/Users/\(secret)/game")
            ),
            snapshot: SystemSnapshot(
                activeServiceLabels: [secret],
                activeApplicationBundleIdentifiers: [],
                activeProcessNames: [],
                preferences: []
            )
        )
        let preflight = PreflightReport(
            findings: [
                PreflightFinding(
                    id: "secret",
                    severity: .warning,
                    category: secret,
                    summary: secret,
                    detail: secret,
                    remediation: secret
                )
            ]
        )
        let status = CleanroomStatus(
            phase: .degraded,
            trigger: TriggerProbe(state: .running, process: journal.trigger, detail: secret),
            journal: journal,
            lastMessage: secret,
            lastResults: [result],
            preflight: preflight,
            diagnosticsHealth: DiagnosticsHealth(eventLogError: secret),
            activeProfile: CleanroomProfileSummary(profile: .phantomForces()),
            deviceCalibration: DeviceCalibration(hardwareIdentifier: secret)
        )
        let events = (0..<40).map { _ in
            TransitionReport(phase: .degraded, message: secret, results: [result])
        }
        let receipt = RecoveryReceipt(journal: journal, results: [result])
        let performance = SessionPerformanceRecord(
            operation: "restore",
            startedAt: .distantPast,
            completedAt: .distantPast,
            thermalState: "nominal",
            results: [result]
        )

        let document = SupportBundleRedactor.makeDocument(
            appVersion: "3.1.0 (5)",
            status: status,
            preflight: preflight,
            events: events,
            receipts: [receipt],
            performance: [performance]
        )
        let encoder = JSONEncoder()
        let evidence = String(decoding: try encoder.encode(document.evidence), as: UTF8.self)

        #expect(!evidence.contains(secret))
        #expect(document.evidence.transitions.count == 30)
        #expect(document.evidence.status.journalPresent)
        #expect(document.manifest.redactedFields.count >= 7)
        #expect(document.manifest.submissionPolicy.contains("no automatic submission"))
        #expect(document.manifest.includedFiles == ["manifest.json", "evidence.json"])
    }
}
