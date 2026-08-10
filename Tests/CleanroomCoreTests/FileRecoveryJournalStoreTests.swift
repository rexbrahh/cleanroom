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

    @Test("duplicate targets and invalid preference values are rejected")
    func structurallyInvalidSnapshotsAreRejected() {
        let snapshot = SystemSnapshot(
            activeServiceLabels: ["duplicate", "duplicate"],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: [
                StoredPreference(
                    domain: "NSGlobalDomain",
                    key: "test",
                    kind: .boolean,
                    wasPresent: true,
                    value: "maybe"
                )
            ]
        )
        let journal = RecoveryJournal(
            trigger: TriggerProcess(
                processIdentifier: 42,
                bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                executableURL: nil
            ),
            snapshot: snapshot
        )

        #expect(throws: CleanroomError.self) {
            try journal.validate()
        }
    }

    @Test("preference presence metadata must match its stored value")
    func inconsistentPreferencePresenceIsRejected() {
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: [
                StoredPreference(
                    domain: "NSGlobalDomain",
                    key: "test",
                    kind: .string,
                    wasPresent: false,
                    value: "unexpected"
                )
            ]
        )

        #expect(throws: CleanroomError.self) {
            try snapshot.validate()
        }
    }

    @Test("verified recovery receipt round-trips separately from active state")
    func receiptRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-receipt-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRecoveryReceiptStore(directoryURL: directory)
        let receipt = RecoveryReceipt(
            sessionIdentifier: UUID(),
            sessionStartedAt: Date(timeIntervalSince1970: 100),
            restoredAt: Date(timeIntervalSince1970: 200),
            triggerBundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
            results: [
                ActionResult(
                    action: "verify restore",
                    target: "test",
                    outcome: .succeeded,
                    detail: "verified",
                    occurredAt: Date(timeIntervalSince1970: 150)
                )
            ]
        )

        try await store.saveReceipt(receipt)

        #expect(try await store.recentReceipts(limit: 3) == [receipt])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.receiptsURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery.json").path))
    }

    @Test("recovery history retains three newest unique sessions")
    func receiptHistoryIsBoundedAndUpserted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-history-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRecoveryReceiptStore(directoryURL: directory)
        var receipts: [RecoveryReceipt] = []
        for index in 0..<4 {
            let receipt = RecoveryReceipt(
                sessionIdentifier: UUID(),
                sessionStartedAt: Date(timeIntervalSince1970: Double(index)),
                restoredAt: Date(timeIntervalSince1970: Double(index)),
                triggerBundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                results: [
                    ActionResult(
                        id: UUID(),
                        action: "verify restore",
                        target: "target-\(index)",
                        outcome: .succeeded,
                        detail: "verified",
                        occurredAt: Date(timeIntervalSince1970: Double(index))
                    )
                ]
            )
            receipts.append(receipt)
            try await store.saveReceipt(receipt)
        }

        #expect(try await store.recentReceipts(limit: 10).map(\.id) == receipts.suffix(3).reversed().map(\.id))

        let updated = RecoveryReceipt(
            sessionIdentifier: receipts[2].sessionIdentifier,
            sessionStartedAt: receipts[2].sessionStartedAt,
            restoredAt: Date(timeIntervalSince1970: 10),
            triggerBundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
            results: [
                ActionResult(
                    action: "verify restore",
                    target: "updated",
                    outcome: .succeeded,
                    detail: "verified",
                    occurredAt: Date(timeIntervalSince1970: 10)
                )
            ]
        )
        try await store.saveReceipt(updated)

        let history = try await store.recentReceipts(limit: 10)
        #expect(history.count == 3)
        #expect(history.first?.id == updated.id)
        #expect(history.first?.results.first?.target == "updated")
    }
}
