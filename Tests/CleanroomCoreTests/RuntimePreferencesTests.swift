import Foundation
import Testing

@testable import CleanroomCore

@Suite("Persistent runtime preferences")
struct RuntimePreferencesTests {
    @Test("missing settings default to automatic transitions enabled")
    func missingSettingsUseSafeDefault() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRuntimePreferencesStore(directoryURL: directory)

        let preferences = try await store.loadPreferences()

        #expect(!preferences.automaticTransitionsPaused)
    }

    @Test("pause intent survives a new store instance")
    func pauseIntentRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = FileRuntimePreferencesStore(directoryURL: directory)
        try await firstStore.savePreferences(
            RuntimePreferences(automaticTransitionsPaused: true)
        )

        let secondStore = FileRuntimePreferencesStore(directoryURL: directory)
        let restored = try await secondStore.loadPreferences()

        #expect(restored.automaticTransitionsPaused)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: secondStore.preferencesURL.path
        )
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    @Test("unsupported settings schema is rejected")
    func unsupportedSchemaIsRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("runtime-preferences.json")
        try Data("{\"schemaVersion\":99,\"automaticTransitionsPaused\":true}".utf8)
            .write(to: url)
        let store = FileRuntimePreferencesStore(directoryURL: directory)

        await #expect(throws: CleanroomError.self) {
            try await store.loadPreferences()
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-runtime-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
