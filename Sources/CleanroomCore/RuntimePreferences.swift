import Foundation

public enum AutomaticTransitionSuppression: String, Codable, Equatable, Sendable {
    case none
    case entry
    case restore
    case all

    public var blocksEntry: Bool { self == .entry || self == .all }
    public var blocksRestore: Bool { self == .restore || self == .all }
}

public struct RuntimePreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let automaticTransitionsPaused: Bool
    public let automaticTransitionSuppression: AutomaticTransitionSuppression
    public let suppressionSessionIdentifier: UUID?
    public let incidentMode: Bool
    public let activeProfileIdentifier: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        automaticTransitionsPaused: Bool = false,
        automaticTransitionSuppression: AutomaticTransitionSuppression = .none,
        suppressionSessionIdentifier: UUID? = nil,
        incidentMode: Bool = false,
        activeProfileIdentifier: String = "roblox-phantom-forces"
    ) {
        self.schemaVersion = schemaVersion
        self.automaticTransitionsPaused = automaticTransitionsPaused
        self.automaticTransitionSuppression = automaticTransitionSuppression
        self.suppressionSessionIdentifier = suppressionSessionIdentifier
        self.incidentMode = incidentMode
        self.activeProfileIdentifier = activeProfileIdentifier
    }

    public func validate() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw CleanroomError.invalidRuntimePreferences(
                "unsupported schema version \(schemaVersion)"
            )
        }
        guard automaticTransitionSuppression != .none || suppressionSessionIdentifier == nil else {
            throw CleanroomError.invalidRuntimePreferences(
                "a suppression session requires an active suppression"
            )
        }
        guard !incidentMode || automaticTransitionsPaused else {
            throw CleanroomError.invalidRuntimePreferences(
                "Incident Mode requires automatic transitions to remain paused"
            )
        }
        guard !activeProfileIdentifier.isEmpty else {
            throw CleanroomError.invalidRuntimePreferences("active profile identifier must not be empty")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case automaticTransitionsPaused
        case automaticTransitionSuppression
        case suppressionSessionIdentifier
        case incidentMode
        case activeProfileIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        automaticTransitionsPaused = try container.decode(Bool.self, forKey: .automaticTransitionsPaused)
        automaticTransitionSuppression =
            try container.decodeIfPresent(
                AutomaticTransitionSuppression.self,
                forKey: .automaticTransitionSuppression
            ) ?? .none
        suppressionSessionIdentifier = try container.decodeIfPresent(
            UUID.self,
            forKey: .suppressionSessionIdentifier
        )
        incidentMode = try container.decodeIfPresent(Bool.self, forKey: .incidentMode) ?? false
        activeProfileIdentifier =
            try container.decodeIfPresent(String.self, forKey: .activeProfileIdentifier)
            ?? "roblox-phantom-forces"
    }
}

public actor FileRuntimePreferencesStore: RuntimePreferencesPersisting {
    public nonisolated let directoryURL: URL
    public nonisolated let preferencesURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.preferencesURL = directoryURL.appendingPathComponent("runtime-preferences.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func loadPreferences() throws -> RuntimePreferences {
        guard fileManager.fileExists(atPath: preferencesURL.path) else {
            return RuntimePreferences()
        }
        do {
            let preferences = try decoder.decode(
                RuntimePreferences.self,
                from: Data(contentsOf: preferencesURL)
            )
            try preferences.validate()
            return RuntimePreferences(
                automaticTransitionsPaused: preferences.automaticTransitionsPaused,
                automaticTransitionSuppression: preferences.automaticTransitionSuppression,
                suppressionSessionIdentifier: preferences.suppressionSessionIdentifier,
                incidentMode: preferences.incidentMode,
                activeProfileIdentifier: preferences.activeProfileIdentifier
            )
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.invalidRuntimePreferences(error.localizedDescription)
        }
    }

    public func savePreferences(_ preferences: RuntimePreferences) throws {
        try preferences.validate()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(preferences).write(to: preferencesURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: preferencesURL.path
            )
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.persistenceFailed(error.localizedDescription)
        }
    }
}
