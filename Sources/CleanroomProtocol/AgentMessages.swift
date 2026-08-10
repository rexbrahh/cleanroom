import CleanroomCore
import Foundation

public enum AgentCommand: Codable, Sendable, Equatable {
    case handshake(AgentHandshakeRequest)
    case status
    case reconcile
    case enter(force: Bool)
    case restore
    case safeLaunch
    case preflight
    case setPaused(Bool)
    case setIncidentMode(Bool)
    case recover(RecoveryAction)
    case recentEvents(limit: Int)
    case performanceTimeline(limit: Int)
    case networkLatency(sampleCount: Int)
    case systemPressure
    case recoveryReceipts(limit: Int)
    case profiles
    case selectProfile(String)
    case validateProfile(CleanroomProfile)
    case saveProfile(CleanroomProfile)
    case deviceCalibration
    case saveDeviceCalibration(DeviceCalibration)
    case exportProfile(String)
    case previewProfileImport(Data)
    case migrateLegacy
}

public enum AgentCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case reconcile
    case enter
    case restore
    case safeLaunch
    case pause
    case incidentMode
    case recovery
    case profileSelection
    case profileEditing
    case calibration
    case legacyMigration
}

public struct AgentHandshakeRequest: Codable, Equatable, Sendable {
    public let clientBuild: CleanroomBuildIdentity
    public let supportedProtocolVersions: [Int]
    public let requiredCapabilities: [AgentCapability]

    public init(
        clientBuild: CleanroomBuildIdentity = .current,
        supportedProtocolVersions: [Int] = [AgentHandshakeResponse.currentProtocolVersion],
        requiredCapabilities: [AgentCapability] = []
    ) {
        self.clientBuild = clientBuild
        self.supportedProtocolVersions = supportedProtocolVersions
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct AgentHandshakeResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public let selectedProtocolVersion: Int?
    public let agentBuild: CleanroomBuildIdentity
    public let capabilities: [AgentCapability]
    public let incompatibility: String?

    public init(
        selectedProtocolVersion: Int?,
        agentBuild: CleanroomBuildIdentity = .current,
        capabilities: [AgentCapability],
        incompatibility: String? = nil
    ) {
        self.selectedProtocolVersion = selectedProtocolVersion
        self.agentBuild = agentBuild
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.incompatibility = incompatibility
    }

    public func validate(required: AgentCapability?) throws {
        guard selectedProtocolVersion == Self.currentProtocolVersion else {
            throw AgentProtocolError.incompatible(
                incompatibility ?? "No supported Cleanroom protocol version was negotiated."
            )
        }
        if let required, !capabilities.contains(required) {
            throw AgentProtocolError.incompatible(
                "The agent does not advertise the required \(required.rawValue) capability."
            )
        }
    }
}

extension AgentCommand {
    public var requiredCapability: AgentCapability? {
        switch self {
        case .handshake, .status, .preflight, .recentEvents, .performanceTimeline, .networkLatency,
            .systemPressure, .recoveryReceipts, .profiles, .validateProfile, .deviceCalibration,
            .exportProfile, .previewProfileImport:
            nil
        case .reconcile: .reconcile
        case .enter: .enter
        case .restore: .restore
        case .safeLaunch: .safeLaunch
        case .setPaused: .pause
        case .setIncidentMode: .incidentMode
        case .recover: .recovery
        case .selectProfile: .profileSelection
        case .saveProfile: .profileEditing
        case .saveDeviceCalibration: .calibration
        case .migrateLegacy: .legacyMigration
        }
    }
}

public struct AgentRequest: Codable, Sendable, Equatable {
    public let identifier: UUID
    public let command: AgentCommand
    public let destructiveRecoveryConfirmed: Bool

    public init(
        identifier: UUID = UUID(),
        command: AgentCommand,
        destructiveRecoveryConfirmed: Bool = false
    ) {
        self.identifier = identifier
        self.command = command
        self.destructiveRecoveryConfirmed = destructiveRecoveryConfirmed
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case command
        case destructiveRecoveryConfirmed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identifier: try container.decode(UUID.self, forKey: .identifier),
            command: try container.decode(AgentCommand.self, forKey: .command),
            destructiveRecoveryConfirmed: try container.decodeIfPresent(
                Bool.self,
                forKey: .destructiveRecoveryConfirmed
            ) ?? false
        )
    }
}

public enum AgentPayload: Codable, Sendable, Equatable {
    case handshake(AgentHandshakeResponse)
    case status(CleanroomStatus)
    case transition(TransitionReport)
    case preflight(PreflightReport)
    case events([TransitionReport])
    case performanceTimeline([SessionPerformanceRecord])
    case networkLatency(NetworkLatencyReport)
    case systemPressure(SystemPressureSample)
    case recoveryReceipts([RecoveryReceipt])
    case profiles([CleanroomProfileSummary])
    case profileValidation(ProfileValidationReport)
    case deviceCalibration(DeviceCalibration?)
    case profileExport(Data)
    case profileImportPreview(ProfileImportPreview)
    case requestInProgress
    case failure(String)
}

public struct AgentResponse: Codable, Sendable, Equatable {
    public let requestIdentifier: UUID
    public let payload: AgentPayload
    public let agentBuild: CleanroomBuildIdentity?

    public init(
        requestIdentifier: UUID,
        payload: AgentPayload,
        agentBuild: CleanroomBuildIdentity? = .current
    ) {
        self.requestIdentifier = requestIdentifier
        self.payload = payload
        self.agentBuild = agentBuild
    }
}

public enum AgentProtocolError: Error, LocalizedError, Sendable {
    case invalidResponse
    case requestMismatch
    case requestTooLarge(Int)
    case timedOut
    case remoteFailure(String)
    case incompatible(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Cleanroom agent returned an invalid response."
        case .requestMismatch:
            "The Cleanroom agent response did not match the request."
        case .requestTooLarge(let maximumBytes):
            "The Cleanroom agent request exceeds the \(maximumBytes)-byte limit."
        case .timedOut:
            "The Cleanroom agent did not respond in time."
        case .remoteFailure(let message):
            message
        case .incompatible(let message):
            "Cleanroom agent incompatibility: \(message)"
        }
    }
}

public enum AgentCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
