import Foundation

public actor FileRecoveryJournalStore: RecoveryJournalPersisting {
    public nonisolated let directoryURL: URL
    public nonisolated let journalURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.journalURL = directoryURL.appendingPathComponent("recovery.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func journalExists() -> Bool {
        fileManager.fileExists(atPath: journalURL.path)
    }

    public func loadJournal() throws -> RecoveryJournal? {
        guard journalExists() else { return nil }
        do {
            let data = try Data(contentsOf: journalURL)
            let journal = try decoder.decode(RecoveryJournal.self, from: data)
            try journal.validate()
            return journal
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.invalidJournal(error.localizedDescription)
        }
    }

    public func saveJournal(_ journal: RecoveryJournal) throws {
        try journal.validate()
        do {
            try ensureDirectory()
            let data = try encoder.encode(journal)
            try data.write(to: journalURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journalURL.path
            )
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clearJournal() throws {
        guard journalExists() else { return }
        do {
            try fileManager.removeItem(at: journalURL)
        } catch {
            throw CleanroomError.persistenceFailed(error.localizedDescription)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public enum CleanroomPaths {
    public static var applicationSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLEANROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cleanroom", isDirectory: true)
    }

    public static var eventLogURL: URL {
        applicationSupportDirectory.appendingPathComponent("events.jsonl")
    }

    public static var heartbeatURL: URL {
        applicationSupportDirectory.appendingPathComponent("heartbeat.json")
    }
}
