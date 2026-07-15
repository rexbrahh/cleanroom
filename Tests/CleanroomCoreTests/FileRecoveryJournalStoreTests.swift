import Foundation
import Testing

@testable import CleanroomCore

@Suite("Recovery journal persistence")
struct FileRecoveryJournalStoreTests {
    @Test("journal round-trips atomically and clears")
    func roundTripAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRecoveryJournalStore(directoryURL: directory)
        let journal = RecoveryJournal(
            trigger: TriggerProcess(
                processIdentifier: 42,
                bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                executableURL: nil
            ),
            snapshot: SystemSnapshot(
                activeServiceLabels: ["org.nix-community.home.skhd"],
                activeApplicationBundleIdentifiers: ["com.raycast.macos"],
                activeProcessNames: ["borders"],
                preferences: []
            )
        )

        try await store.saveJournal(journal)
        let loaded = try #require(try await store.loadJournal())
        #expect(loaded.sessionIdentifier == journal.sessionIdentifier)
        #expect(loaded.snapshot == journal.snapshot)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.journalURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try await store.clearJournal()
        #expect(!(await store.journalExists()))
    }

    @Test("corrupt journal is surfaced and retained")
    func corruptJournalIsRetained() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileRecoveryJournalStore(directoryURL: directory)
        try Data("not-json".utf8).write(to: store.journalURL)

        await #expect(throws: CleanroomError.self) {
            _ = try await store.loadJournal()
        }
        #expect(await store.journalExists())
    }
}
