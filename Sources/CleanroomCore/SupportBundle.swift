import Foundation

public struct SupportOutcomeCounts: Codable, Equatable, Sendable {
    public let succeeded: Int
    public let skipped: Int
    public let warning: Int
    public let failed: Int
    public let unknown: Int

    public init(results: [ActionResult]) {
        succeeded = results.count { $0.outcome == .succeeded }
        skipped = results.count { $0.outcome == .skipped }
        warning = results.count { $0.outcome == .warning }
        failed = results.count { $0.outcome == .failed }
        unknown = results.count { $0.outcome == .unknown }
    }
}

public struct SupportBundleManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let includedFiles: [String]
    public let limits: [String: Int]
    public let redactedFields: [String]
    public let submissionPolicy: String
}

public struct SupportStatusEvidence: Codable, Equatable, Sendable {
    public let phase: CleanroomPhase?
    public let triggerState: ProbeState?
    public let journalPresent: Bool
    public let heartbeatAt: Date?
    public let diagnosticsHealthy: Bool?
    public let incidentMode: Bool?
}

public struct SupportPreflightEvidence: Codable, Equatable, Sendable {
    public let generatedAt: Date?
    public let probes: [PreflightProbeEvidence]
    public let informationCount: Int
    public let warningCount: Int
    public let criticalCount: Int
}

public struct SupportTransitionEvidence: Codable, Equatable, Sendable {
    public let phase: CleanroomPhase
    public let occurredAt: Date?
    public let outcomes: SupportOutcomeCounts
}

public struct SupportReceiptEvidence: Codable, Equatable, Sendable {
    public let sessionStartedAt: Date
    public let restoredAt: Date
    public let outcomes: SupportOutcomeCounts
}

public struct SupportPerformanceEvidence: Codable, Equatable, Sendable {
    public let operation: String
    public let startedAt: Date
    public let durationMilliseconds: Int
    public let thermalState: String
    public let actionCount: Int
    public let failureCount: Int
}

public struct SupportBundleEvidence: Codable, Equatable, Sendable {
    public let status: SupportStatusEvidence
    public let preflight: SupportPreflightEvidence
    public let transitions: [SupportTransitionEvidence]
    public let recoveryReceipts: [SupportReceiptEvidence]
    public let performance: [SupportPerformanceEvidence]
}

public struct SupportBundleDocument: Equatable, Sendable {
    public let manifest: SupportBundleManifest
    public let evidence: SupportBundleEvidence
}

public enum SupportBundleRedactor {
    public static let eventLimit = 30
    public static let receiptLimit = 3
    public static let performanceLimit = 30

    public static func makeDocument(
        generatedAt: Date = Date(),
        appVersion: String,
        status: CleanroomStatus?,
        preflight: PreflightReport?,
        events: [TransitionReport],
        receipts: [RecoveryReceipt],
        performance: [SessionPerformanceRecord]
    ) -> SupportBundleDocument {
        let manifest = SupportBundleManifest(
            schemaVersion: SupportBundleManifest.currentSchemaVersion,
            generatedAt: generatedAt,
            appVersion: appVersion,
            includedFiles: ["manifest.json", "evidence.json"],
            limits: [
                "transitionEvents": eventLimit,
                "recoveryReceipts": receiptLimit,
                "performanceRecords": performanceLimit,
            ],
            redactedFields: [
                "trigger process identifier, bundle identifier, and executable URL",
                "recovery journal identifiers, trigger, snapshot, and preference values",
                "action target and detail",
                "preflight finding detail and remediation",
                "profile contents and hardware identifier",
                "network target addresses and names",
                "diagnostic error strings and user file paths",
            ],
            submissionPolicy: "local-only; no automatic submission"
        )
        let evidence = SupportBundleEvidence(
            status: SupportStatusEvidence(
                phase: status?.phase,
                triggerState: status?.trigger.state,
                journalPresent: status?.journal != nil,
                heartbeatAt: status?.heartbeatAt,
                diagnosticsHealthy: status?.diagnosticsHealth?.isHealthy,
                incidentMode: status?.incidentMode
            ),
            preflight: SupportPreflightEvidence(
                generatedAt: preflight?.generatedAt,
                probes: preflight?.probes ?? [],
                informationCount: preflight?.findings.count { $0.severity == .information } ?? 0,
                warningCount: preflight?.findings.count { $0.severity == .warning } ?? 0,
                criticalCount: preflight?.findings.count { $0.severity == .critical } ?? 0
            ),
            transitions: events.prefix(eventLimit).map {
                SupportTransitionEvidence(
                    phase: $0.phase,
                    occurredAt: $0.occurredAt,
                    outcomes: SupportOutcomeCounts(results: $0.results)
                )
            },
            recoveryReceipts: receipts.prefix(receiptLimit).map {
                SupportReceiptEvidence(
                    sessionStartedAt: $0.sessionStartedAt,
                    restoredAt: $0.restoredAt,
                    outcomes: SupportOutcomeCounts(results: $0.results)
                )
            },
            performance: performance.prefix(performanceLimit).map {
                SupportPerformanceEvidence(
                    operation: $0.operation,
                    startedAt: $0.startedAt,
                    durationMilliseconds: $0.durationMilliseconds,
                    thermalState: $0.thermalState,
                    actionCount: $0.actions.count,
                    failureCount: $0.failureCount
                )
            }
        )
        return SupportBundleDocument(manifest: manifest, evidence: evidence)
    }
}
