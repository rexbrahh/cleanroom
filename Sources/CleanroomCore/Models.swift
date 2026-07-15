import Foundation

public enum CleanroomPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case entering
    case active
    case restoring
    case degraded
    case paused
}

public enum ProbeState: String, Codable, Sendable {
    case running
    case stopped
    case unknown
}

public struct TriggerProcess: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let executableURL: URL?

    public init(processIdentifier: Int32, bundleIdentifier: String, executableURL: URL?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.executableURL = executableURL
    }
}

public struct TriggerProbe: Codable, Equatable, Sendable {
    public let state: ProbeState
    public let process: TriggerProcess?
    public let detail: String?

    public init(state: ProbeState, process: TriggerProcess? = nil, detail: String? = nil) {
        self.state = state
        self.process = process
        self.detail = detail
    }
}

public enum ActionOutcome: String, Codable, Sendable {
    case succeeded
    case skipped
    case warning
    case failed
    case unknown

    public var blocksCompletion: Bool {
        self == .failed || self == .unknown
    }
}

public struct ActionResult: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: String
    public let target: String
    public let outcome: ActionOutcome
    public let detail: String
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        action: String,
        target: String,
        outcome: ActionOutcome,
        detail: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.target = target
        self.outcome = outcome
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

public struct ManagedApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public let name: String
    public let bundleIdentifier: String
    public let executableName: String
    public let restoreWhenPreviouslyRunning: Bool

    public init(
        name: String,
        bundleIdentifier: String,
        executableName: String,
        restoreWhenPreviouslyRunning: Bool = true
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.restoreWhenPreviouslyRunning = restoreWhenPreviouslyRunning
    }
}

public struct ManagedService: Codable, Equatable, Identifiable, Sendable {
    public var id: String { label }
    public let name: String
    public let label: String
    public let propertyListURL: URL

    public init(name: String, label: String, propertyListURL: URL) {
        self.name = name
        self.label = label
        self.propertyListURL = propertyListURL
    }
}

public struct ManagedProcess: Codable, Equatable, Identifiable, Sendable {
    public var id: String { executableName }
    public let name: String
    public let executableName: String
    public let relaunchCommand: [String]

    public init(name: String, executableName: String, relaunchCommand: [String]) {
        self.name = name
        self.executableName = executableName
        self.relaunchCommand = relaunchCommand
    }
}

public enum PreferenceKind: String, Codable, Sendable {
    case boolean
    case integer
    case string
}

public struct PreferenceAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(domain):\(key)" }
    public let domain: String
    public let key: String
    public let kind: PreferenceKind
    public let activeValue: String
    public let synchronizeProcess: String?

    public init(
        domain: String,
        key: String,
        kind: PreferenceKind,
        activeValue: String,
        synchronizeProcess: String? = nil
    ) {
        self.domain = domain
        self.key = key
        self.kind = kind
        self.activeValue = activeValue
        self.synchronizeProcess = synchronizeProcess
    }
}

public struct StoredPreference: Codable, Equatable, Sendable {
    public let domain: String
    public let key: String
    public let kind: PreferenceKind
    public let wasPresent: Bool
    public let value: String?

    public init(
        domain: String,
        key: String,
        kind: PreferenceKind,
        wasPresent: Bool,
        value: String?
    ) {
        self.domain = domain
        self.key = key
        self.kind = kind
        self.wasPresent = wasPresent
        self.value = value
    }
}

public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let activeServiceLabels: [String]
    public let activeApplicationBundleIdentifiers: [String]
    public let activeProcessNames: [String]
    public let preferences: [StoredPreference]

    public init(
        activeServiceLabels: [String],
        activeApplicationBundleIdentifiers: [String],
        activeProcessNames: [String],
        preferences: [StoredPreference]
    ) {
        self.activeServiceLabels = activeServiceLabels
        self.activeApplicationBundleIdentifiers = activeApplicationBundleIdentifiers
        self.activeProcessNames = activeProcessNames
        self.preferences = preferences
    }
}

public struct RecoveryJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: UUID
    public let createdAt: Date
    public let trigger: TriggerProcess
    public let snapshot: SystemSnapshot

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessionIdentifier: UUID = UUID(),
        createdAt: Date = Date(),
        trigger: TriggerProcess,
        snapshot: SystemSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.createdAt = createdAt
        self.trigger = trigger
        self.snapshot = snapshot
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CleanroomError.unsupportedJournalSchema(schemaVersion)
        }
        guard trigger.processIdentifier > 0 else {
            throw CleanroomError.invalidJournal("trigger PID must be positive")
        }
        guard trigger.bundleIdentifier == CleanroomProfile.robloxBundleIdentifier else {
            throw CleanroomError.invalidJournal("unexpected trigger bundle identifier")
        }
    }
}

public enum PreflightSeverity: String, Codable, Comparable, Sendable {
    case information
    case warning
    case critical

    public static func < (lhs: PreflightSeverity, rhs: PreflightSeverity) -> Bool {
        let order: [Self] = [.information, .warning, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct PreflightFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let severity: PreflightSeverity
    public let category: String
    public let summary: String
    public let detail: String
    public let remediation: String?

    public init(
        id: String,
        severity: PreflightSeverity,
        category: String,
        summary: String,
        detail: String,
        remediation: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.summary = summary
        self.detail = detail
        self.remediation = remediation
    }
}

public struct PreflightReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let findings: [PreflightFinding]

    public init(generatedAt: Date = Date(), findings: [PreflightFinding]) {
        self.generatedAt = generatedAt
        self.findings = findings.sorted { $0.severity > $1.severity }
    }

    public var highestSeverity: PreflightSeverity {
        findings.map(\.severity).max() ?? .information
    }
}

public struct TransitionReport: Codable, Equatable, Sendable {
    public let phase: CleanroomPhase
    public let message: String
    public let results: [ActionResult]
    public let preflight: PreflightReport?
    public let occurredAt: Date?

    public init(
        phase: CleanroomPhase,
        message: String,
        results: [ActionResult] = [],
        preflight: PreflightReport? = nil,
        occurredAt: Date? = Date()
    ) {
        self.phase = phase
        self.message = message
        self.results = results
        self.preflight = preflight
        self.occurredAt = occurredAt
    }
}

public struct CleanroomStatus: Codable, Equatable, Sendable {
    public let phase: CleanroomPhase
    public let trigger: TriggerProbe
    public let journal: RecoveryJournal?
    public let lastMessage: String
    public let lastResults: [ActionResult]
    public let preflight: PreflightReport?
    public let agentStartedAt: Date?
    public let heartbeatAt: Date?

    public init(
        phase: CleanroomPhase,
        trigger: TriggerProbe,
        journal: RecoveryJournal?,
        lastMessage: String,
        lastResults: [ActionResult],
        preflight: PreflightReport?,
        agentStartedAt: Date? = nil,
        heartbeatAt: Date? = nil
    ) {
        self.phase = phase
        self.trigger = trigger
        self.journal = journal
        self.lastMessage = lastMessage
        self.lastResults = lastResults
        self.preflight = preflight
        self.agentStartedAt = agentStartedAt
        self.heartbeatAt = heartbeatAt
    }
}

public enum RecoveryAction: String, Codable, Sendable {
    case retryEntry
    case retryRestore
    case discardJournal
}

public enum CleanroomError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedJournalSchema(Int)
    case invalidJournal(String)
    case missingTrigger
    case triggerUnknown(String)
    case noRecoveryJournal
    case mutationFailed(String)
    case persistenceFailed(String)
    case invalidRuntimePreferences(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedJournalSchema(let version):
            "Unsupported recovery journal schema \(version)."
        case .invalidJournal(let reason):
            "Invalid recovery journal: \(reason)"
        case .missingTrigger:
            "Roblox is not running."
        case .triggerUnknown(let detail):
            "Roblox state is unknown: \(detail)"
        case .noRecoveryJournal:
            "No recovery journal exists."
        case .mutationFailed(let detail):
            "Cleanroom mutation failed: \(detail)"
        case .persistenceFailed(let detail):
            "Cleanroom persistence failed: \(detail)"
        case .invalidRuntimePreferences(let detail):
            "Invalid runtime preferences: \(detail)"
        }
    }
}
