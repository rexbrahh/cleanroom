import Foundation

public actor FileProfileStore: ProfilePersisting {
    public nonisolated let profilesURL: URL
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.profilesURL = directoryURL.appendingPathComponent("profiles.json")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func loadProfiles() throws -> [CleanroomProfile] {
        guard fileManager.fileExists(atPath: profilesURL.path) else { return [] }
        do {
            let profiles = try decoder.decode([CleanroomProfile].self, from: Data(contentsOf: profilesURL))
            try validate(profiles)
            return profiles
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.persistenceFailed("profiles: \(error.localizedDescription)")
        }
    }

    public func saveProfiles(_ profiles: [CleanroomProfile]) throws {
        try validate(profiles)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(profiles).write(to: profilesURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilesURL.path)
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.persistenceFailed("profiles: \(error.localizedDescription)")
        }
    }

    private func validate(_ profiles: [CleanroomProfile]) throws {
        guard profiles.count <= 10, Set(profiles.map(\.identifier)).count == profiles.count else {
            throw CleanroomError.invalidProfile("at most ten unique custom profiles are allowed")
        }
        for profile in profiles {
            let report = profile.validationReport()
            guard report.isValid else {
                throw CleanroomError.invalidProfile(report.errors.joined(separator: " "))
            }
        }
    }
}
