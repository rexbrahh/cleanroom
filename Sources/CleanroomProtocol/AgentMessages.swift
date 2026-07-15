import CleanroomCore
import Foundation

public enum AgentCommand: Codable, Sendable, Equatable {
    case status
    case reconcile
    case enter(force: Bool)
    case restore
    case preflight
    case setPaused(Bool)
    case recover(RecoveryAction)
    case recentEvents(limit: Int)
    case migrateLegacy
}

public struct AgentRequest: Codable, Sendable, Equatable {
    public let identifier: UUID
    public let command: AgentCommand

    public init(identifier: UUID = UUID(), command: AgentCommand) {
        self.identifier = identifier
        self.command = command
    }
}

public enum AgentPayload: Codable, Sendable, Equatable {
    case status(CleanroomStatus)
    case transition(TransitionReport)
    case preflight(PreflightReport)
    case events([TransitionReport])
    case failure(String)
}

public struct AgentResponse: Codable, Sendable, Equatable {
    public let requestIdentifier: UUID
    public let payload: AgentPayload

    public init(requestIdentifier: UUID, payload: AgentPayload) {
        self.requestIdentifier = requestIdentifier
        self.payload = payload
    }
}

public enum AgentProtocolError: Error, LocalizedError, Sendable {
    case invalidResponse
    case requestMismatch
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Cleanroom agent returned an invalid response."
        case .requestMismatch:
            "The Cleanroom agent response did not match the request."
        case .remoteFailure(let message):
            message
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
