import Foundation

public struct RuntimePreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let automaticTransitionsPaused: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        automaticTransitionsPaused: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.automaticTransitionsPaused = automaticTransitionsPaused
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CleanroomError.invalidRuntimePreferences(
                "unsupported schema version \(schemaVersion)"
            )
        }
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
            return preferences
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
