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

public struct StoredApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifiers: [Int32]
    public let bundleURLs: [URL]
    public let executableURLs: [URL]

    public init(
        bundleIdentifier: String,
        processIdentifiers: [Int32],
        bundleURLs: [URL],
        executableURLs: [URL]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifiers = processIdentifiers
        self.bundleURLs = bundleURLs
        self.executableURLs = executableURLs
    }
}

public struct StoredProcess: Codable, Equatable, Sendable {
    public let executableName: String
    public let processIdentifiers: [Int32]
    public let executableURLs: [URL]

    public init(
        executableName: String,
        processIdentifiers: [Int32],
        executableURLs: [URL] = []
    ) {
        self.executableName = executableName
        self.processIdentifiers = processIdentifiers
        self.executableURLs = executableURLs
    }

    private enum CodingKeys: String, CodingKey {
        case executableName
        case processIdentifiers
        case executableURLs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executableName: try container.decode(String.self, forKey: .executableName),
            processIdentifiers: try container.decode([Int32].self, forKey: .processIdentifiers),
            executableURLs: try container.decodeIfPresent([URL].self, forKey: .executableURLs) ?? []
        )
    }
}

public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let activeServiceLabels: [String]
    public let activeApplicationBundleIdentifiers: [String]
    public let activeProcessNames: [String]
    public let preferences: [StoredPreference]
    public let applications: [StoredApplication]
    public let processes: [StoredProcess]

    public init(
        activeServiceLabels: [String],
        activeApplicationBundleIdentifiers: [String],
        activeProcessNames: [String],
        preferences: [StoredPreference],
        applications: [StoredApplication]? = nil,
        processes: [StoredProcess]? = nil
    ) {
        self.activeServiceLabels = activeServiceLabels
        self.activeApplicationBundleIdentifiers = activeApplicationBundleIdentifiers
        self.activeProcessNames = activeProcessNames
        self.preferences = preferences
        self.applications =
            applications
            ?? activeApplicationBundleIdentifiers.map {
                StoredApplication(
                    bundleIdentifier: $0,
                    processIdentifiers: [],
                    bundleURLs: [],
                    executableURLs: []
                )
            }
        self.processes =
            processes
            ?? activeProcessNames.map {
                StoredProcess(executableName: $0, processIdentifiers: [])
            }
    }

    private enum CodingKeys: String, CodingKey {
        case activeServiceLabels
        case activeApplicationBundleIdentifiers
        case activeProcessNames
        case preferences
        case applications
        case processes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serviceLabels = try container.decode([String].self, forKey: .activeServiceLabels)
        let bundleIdentifiers = try container.decode([String].self, forKey: .activeApplicationBundleIdentifiers)
        let processNames = try container.decode([String].self, forKey: .activeProcessNames)
        let preferences = try container.decode([StoredPreference].self, forKey: .preferences)
        self.init(
            activeServiceLabels: serviceLabels,
            activeApplicationBundleIdentifiers: bundleIdentifiers,
            activeProcessNames: processNames,
            preferences: preferences,
            applications: try container.decodeIfPresent([StoredApplication].self, forKey: .applications),
            processes: try container.decodeIfPresent([StoredProcess].self, forKey: .processes)
        )
    }

    public func validate() throws {
        try requireUnique(activeServiceLabels, name: "active service labels")
        try requireUnique(activeApplicationBundleIdentifiers, name: "active application bundle identifiers")
        try requireUnique(activeProcessNames, name: "active process names")
        try requireUnique(applications.map(\.bundleIdentifier), name: "stored applications")
        try requireUnique(processes.map(\.executableName), name: "stored processes")

        guard Set(applications.map(\.bundleIdentifier)) == Set(activeApplicationBundleIdentifiers) else {
            throw CleanroomError.invalidJournal("application provenance does not match the active application set")
        }
        guard Set(processes.map(\.executableName)) == Set(activeProcessNames) else {
            throw CleanroomError.invalidJournal("process provenance does not match the active process set")
        }

        let preferenceKeys = preferences.map { "\($0.domain)\u{0}\($0.key)\u{0}\($0.kind.rawValue)" }
        try requireUnique(preferenceKeys, name: "stored preferences")
        for preference in preferences {
            guard !preference.domain.isEmpty, !preference.key.isEmpty else {
                throw CleanroomError.invalidJournal("stored preference domain and key must not be empty")
            }
            guard preference.wasPresent == (preference.value != nil) else {
                throw CleanroomError.invalidJournal(
                    "stored preference \(preference.domain):\(preference.key) has inconsistent presence metadata"
                )
            }
            guard let value = preference.value else { continue }
            switch preference.kind {
            case .boolean:
                guard ["0", "1", "false", "no", "true", "yes"].contains(value.lowercased()) else {
                    throw CleanroomError.invalidJournal(
                        "stored preference \(preference.domain):\(preference.key) is not a boolean"
                    )
                }
            case .integer:
                guard Int(value) != nil else {
                    throw CleanroomError.invalidJournal(
                        "stored preference \(preference.domain):\(preference.key) is not an integer"
                    )
                }
            case .string:
                break
            }
        }

        for application in applications {
            guard !application.bundleIdentifier.isEmpty else {
                throw CleanroomError.invalidJournal("stored application bundle identifier must not be empty")
            }
            try requireValidProcessIdentifiers(application.processIdentifiers, target: application.bundleIdentifier)
            guard application.bundleURLs.allSatisfy(\.isFileURL), application.executableURLs.allSatisfy(\.isFileURL)
            else {
                throw CleanroomError.invalidJournal(
                    "stored application \(application.bundleIdentifier) contains a non-file URL"
                )
            }
        }
        for process in processes {
            guard !process.executableName.isEmpty else {
                throw CleanroomError.invalidJournal("stored process executable name must not be empty")
            }
            try requireValidProcessIdentifiers(process.processIdentifiers, target: process.executableName)
            guard process.executableURLs.allSatisfy(\.isFileURL) else {
                throw CleanroomError.invalidJournal(
                    "stored process \(process.executableName) contains a non-file URL"
                )
            }
        }
    }

    private func requireUnique(_ values: [String], name: String) throws {
        guard values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count else {
            throw CleanroomError.invalidJournal("\(name) must be non-empty and unique")
        }
    }

    private func requireValidProcessIdentifiers(_ values: [Int32], target: String) throws {
        guard values.allSatisfy({ $0 > 0 }), Set(values).count == values.count else {
            throw CleanroomError.invalidJournal(
                "stored process identifiers for \(target) must be positive and unique"
            )
        }
    }
}

public struct RecoveryJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: UUID
    public let createdAt: Date
    public let trigger: TriggerProcess
    public let snapshot: SystemSnapshot
    public let safeLaunchPrepared: Bool?
    public let profileIdentifier: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessionIdentifier: UUID = UUID(),
        createdAt: Date = Date(),
        trigger: TriggerProcess,
        snapshot: SystemSnapshot,
        safeLaunchPrepared: Bool? = nil,
        profileIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.createdAt = createdAt
        self.trigger = trigger
        self.snapshot = snapshot
        self.safeLaunchPrepared = safeLaunchPrepared
        self.profileIdentifier = profileIdentifier
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CleanroomError.unsupportedJournalSchema(schemaVersion)
        }
        guard trigger.processIdentifier > 0 || (trigger.processIdentifier == 0 && safeLaunchPrepared == true) else {
            throw CleanroomError.invalidJournal("trigger PID must be positive unless safe launch is prepared")
        }
        guard !trigger.bundleIdentifier.isEmpty else {
            throw CleanroomError.invalidJournal("trigger bundle identifier must not be empty")
        }
        guard profileIdentifier?.isEmpty != true else {
            throw CleanroomError.invalidJournal("profile identifier must not be empty")
        }
        try snapshot.validate()
    }
}

public struct RecoveryReceipt: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UUID { sessionIdentifier }
    public let schemaVersion: Int
    public let sessionIdentifier: UUID
    public let sessionStartedAt: Date
    public let restoredAt: Date
    public let triggerBundleIdentifier: String
    public let results: [ActionResult]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessionIdentifier: UUID,
        sessionStartedAt: Date,
        restoredAt: Date = Date(),
        triggerBundleIdentifier: String,
        results: [ActionResult]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.sessionStartedAt = sessionStartedAt
        self.restoredAt = restoredAt
        self.triggerBundleIdentifier = triggerBundleIdentifier
        self.results = results
    }

    public init(journal: RecoveryJournal, restoredAt: Date = Date(), results: [ActionResult]) {
        self.init(
            sessionIdentifier: journal.sessionIdentifier,
            sessionStartedAt: journal.createdAt,
            restoredAt: restoredAt,
            triggerBundleIdentifier: journal.trigger.bundleIdentifier,
            results: results
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CleanroomError.invalidReceipt("unsupported schema \(schemaVersion)")
        }
        guard !triggerBundleIdentifier.isEmpty else {
            throw CleanroomError.invalidReceipt("trigger bundle identifier must not be empty")
        }
        guard !results.isEmpty, !results.contains(where: { $0.outcome.blocksCompletion }) else {
            throw CleanroomError.invalidReceipt("results must prove a complete restoration")
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

public enum PreflightProbeState: String, Codable, Equatable, Sendable {
    case succeeded
    case incomplete
}

public struct PreflightProbeEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let state: PreflightProbeState
    public let checkedAt: Date
    public let lastSucceededAt: Date?
    public let ageSeconds: Int?

    public init(
        id: String,
        name: String,
        state: PreflightProbeState,
        checkedAt: Date,
        lastSucceededAt: Date?
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.checkedAt = checkedAt
        self.lastSucceededAt = lastSucceededAt
        self.ageSeconds = lastSucceededAt.map { max(0, Int(checkedAt.timeIntervalSince($0))) }
    }

    public func age(at date: Date) -> TimeInterval? {
        lastSucceededAt.map { max(0, date.timeIntervalSince($0)) }
    }
}

public struct PreflightReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let findings: [PreflightFinding]
    public let probes: [PreflightProbeEvidence]?

    public init(
        generatedAt: Date = Date(),
        findings: [PreflightFinding],
        probes: [PreflightProbeEvidence]? = nil
    ) {
        self.generatedAt = generatedAt
        self.findings = findings.sorted { $0.severity > $1.severity }
        self.probes = probes
    }

    public var highestSeverity: PreflightSeverity {
        findings.map(\.severity).max() ?? .information
    }

    public func isFreshAndComplete(
        at date: Date = Date(),
        maximumAge: TimeInterval = 120
    ) -> Bool {
        guard let probes, !probes.isEmpty else { return false }
        return probes.allSatisfy {
            $0.state == .succeeded && ($0.age(at: date) ?? .infinity) <= maximumAge
        }
    }

    public func isReady(at date: Date = Date()) -> Bool {
        isFreshAndComplete(at: date) && highestSeverity == .information
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

public struct PerformanceActionPoint: Codable, Equatable, Sendable {
    public let action: String
    public let target: String
    public let outcome: ActionOutcome
    public let completedAfterMilliseconds: Int

    public init(action: String, target: String, outcome: ActionOutcome, completedAfterMilliseconds: Int) {
        self.action = action
        self.target = target
        self.outcome = outcome
        self.completedAfterMilliseconds = max(0, completedAfterMilliseconds)
    }
}

public struct SessionPerformanceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operation: String
    public let startedAt: Date
    public let completedAt: Date
    public let durationMilliseconds: Int
    public let thermalState: String
    public let failureCount: Int
    public let actions: [PerformanceActionPoint]
    public let contentBoundary: String

    public init(
        id: UUID = UUID(),
        operation: String,
        startedAt: Date,
        completedAt: Date,
        thermalState: String,
        results: [ActionResult]
    ) {
        self.id = id
        self.operation = operation
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000))
        self.thermalState = thermalState
        self.failureCount = results.count { $0.outcome.blocksCompletion }
        self.actions = results.map {
            PerformanceActionPoint(
                action: $0.action,
                target: $0.target,
                outcome: $0.outcome,
                completedAfterMilliseconds: Int($0.occurredAt.timeIntervalSince(startedAt) * 1_000)
            )
        }
        self.contentBoundary = "system-metadata-only; no gameplay content"
    }
}

public struct CommandObservation: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct NetworkLatencyReport: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let target: String?
    public let sampleCount: Int
    public let averageMilliseconds: Double?
    public let jitterMilliseconds: Double?
    public let packetLossPercent: Double?
    public let error: String?
    public let readOnly: Bool
    public let commands: [CommandObservation]

    public init(
        capturedAt: Date = Date(),
        target: String?,
        sampleCount: Int,
        averageMilliseconds: Double?,
        jitterMilliseconds: Double?,
        packetLossPercent: Double?,
        error: String? = nil,
        commands: [CommandObservation]
    ) {
        self.capturedAt = capturedAt
        self.target = target
        self.sampleCount = sampleCount
        self.averageMilliseconds = averageMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.packetLossPercent = packetLossPercent
        self.error = error
        self.readOnly = true
        self.commands = commands
    }
}

public enum ThermalPressureLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SystemPressureSample: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let thermal: ThermalPressureLevel
    public let batteryPercent: Int?
    public let onACPower: Bool?

    public init(
        capturedAt: Date = Date(),
        thermal: ThermalPressureLevel,
        batteryPercent: Int?,
        onACPower: Bool?
    ) {
        self.capturedAt = capturedAt
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

public struct SystemAlertThresholds: Codable, Equatable, Sendable {
    public let thermal: ThermalPressureLevel
    public let batteryPercent: Int

    public init(thermal: ThermalPressureLevel = .serious, batteryPercent: Int = 20) {
        self.thermal = thermal
        self.batteryPercent = min(max(batteryPercent, 5), 50)
    }
}

public enum SystemPressureAlert: String, Codable, Equatable, Sendable {
    case thermal
    case battery
}

public struct SystemPressureAlertGate: Sendable {
    private var thermalExceeded = false
    private var batteryExceeded = false

    public init() {}

    public mutating func crossings(
        for sample: SystemPressureSample,
        thresholds: SystemAlertThresholds
    ) -> [SystemPressureAlert] {
        var alerts: [SystemPressureAlert] = []
        if sample.thermal != .unknown {
            let exceeded = sample.thermal >= thresholds.thermal
            if exceeded, !thermalExceeded { alerts.append(.thermal) }
            thermalExceeded = exceeded
        }
        if let batteryPercent = sample.batteryPercent, let onACPower = sample.onACPower {
            let exceeded = !onACPower && batteryPercent <= thresholds.batteryPercent
            if exceeded, !batteryExceeded { alerts.append(.battery) }
            batteryExceeded = exceeded
        }
        return alerts
    }
}

public struct DiagnosticsHealth: Codable, Equatable, Sendable {
    public let eventLogError: String?
    public let heartbeatError: String?
    public let eventReadError: String?

    public init(
        eventLogError: String? = nil,
        heartbeatError: String? = nil,
        eventReadError: String? = nil
    ) {
        self.eventLogError = eventLogError
        self.heartbeatError = heartbeatError
        self.eventReadError = eventReadError
    }

    public var isHealthy: Bool {
        eventLogError == nil && heartbeatError == nil && eventReadError == nil
    }
}

public struct DeviceCalibration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { hardwareIdentifier }
    public let hardwareIdentifier: String
    public let pointerLinearEnabled: Bool
    public let preferredDisplayRefreshRateHertz: Int
    public let automaticRestoreDebounceSeconds: Double

    public init(
        hardwareIdentifier: String,
        pointerLinearEnabled: Bool = true,
        preferredDisplayRefreshRateHertz: Int = 120,
        automaticRestoreDebounceSeconds: Double = 5
    ) {
        self.hardwareIdentifier = hardwareIdentifier
        self.pointerLinearEnabled = pointerLinearEnabled
        self.preferredDisplayRefreshRateHertz = preferredDisplayRefreshRateHertz
        self.automaticRestoreDebounceSeconds = automaticRestoreDebounceSeconds
    }

    public func validate() throws {
        guard !hardwareIdentifier.isEmpty, hardwareIdentifier.count <= 128 else {
            throw CleanroomError.invalidCalibration("hardware identity is missing or too long")
        }
        guard (30...360).contains(preferredDisplayRefreshRateHertz) else {
            throw CleanroomError.invalidCalibration("display refresh rate must be 30...360 Hz")
        }
        guard (0...30).contains(automaticRestoreDebounceSeconds) else {
            throw CleanroomError.invalidCalibration("restore debounce must be 0...30 seconds")
        }
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
    public let diagnosticsHealth: DiagnosticsHealth?
    public let incidentMode: Bool?
    public let activeProfile: CleanroomProfileSummary?
    public let deviceCalibration: DeviceCalibration?

    public init(
        phase: CleanroomPhase,
        trigger: TriggerProbe,
        journal: RecoveryJournal?,
        lastMessage: String,
        lastResults: [ActionResult],
        preflight: PreflightReport?,
        agentStartedAt: Date? = nil,
        heartbeatAt: Date? = nil,
        diagnosticsHealth: DiagnosticsHealth? = nil,
        incidentMode: Bool? = nil,
        activeProfile: CleanroomProfileSummary? = nil,
        deviceCalibration: DeviceCalibration? = nil
    ) {
        self.phase = phase
        self.trigger = trigger
        self.journal = journal
        self.lastMessage = lastMessage
        self.lastResults = lastResults
        self.preflight = preflight
        self.agentStartedAt = agentStartedAt
        self.heartbeatAt = heartbeatAt
        self.diagnosticsHealth = diagnosticsHealth
        self.incidentMode = incidentMode
        self.activeProfile = activeProfile
        self.deviceCalibration = deviceCalibration
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
    case invalidReceipt(String)
    case invalidProfile(String)
    case invalidCalibration(String)
    case transitionInProgress(String)

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
        case .invalidReceipt(let detail):
            "Invalid recovery receipt: \(detail)"
        case .invalidProfile(let detail):
            "Invalid profile: \(detail)"
        case .invalidCalibration(let detail):
            "Invalid device calibration: \(detail)"
        case .transitionInProgress(let transition):
            "A Cleanroom transition is already in progress: \(transition)."
        }
    }
}
