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

    @Test("v1 settings migrate with no retry suppression")
    func v1SettingsMigrate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("runtime-preferences.json")
        try Data("{\"schemaVersion\":1,\"automaticTransitionsPaused\":true}".utf8)
            .write(to: url)

        let preferences = try await FileRuntimePreferencesStore(directoryURL: directory).loadPreferences()

        #expect(preferences.schemaVersion == RuntimePreferences.currentSchemaVersion)
        #expect(preferences.automaticTransitionsPaused)
        #expect(preferences.automaticTransitionSuppression == .none)
        #expect(preferences.suppressionSessionIdentifier == nil)
        #expect(!preferences.incidentMode)
    }

    @Test("retry suppression and its recovery session round-trip")
    func retrySuppressionRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRuntimePreferencesStore(directoryURL: directory)
        let sessionIdentifier = UUID()

        try await store.savePreferences(
            RuntimePreferences(
                automaticTransitionSuppression: .restore,
                suppressionSessionIdentifier: sessionIdentifier
            )
        )
        let restored = try await store.loadPreferences()

        #expect(restored.automaticTransitionSuppression == .restore)
        #expect(restored.suppressionSessionIdentifier == sessionIdentifier)
    }

    @Test("Incident Mode survives a new settings-store instance")
    func incidentModeRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await FileRuntimePreferencesStore(directoryURL: directory).savePreferences(
            RuntimePreferences(automaticTransitionsPaused: true, incidentMode: true)
        )

        let restored = try await FileRuntimePreferencesStore(directoryURL: directory).loadPreferences()

        #expect(restored.schemaVersion == RuntimePreferences.currentSchemaVersion)
        #expect(restored.automaticTransitionsPaused)
        #expect(restored.incidentMode)
    }

    @Test("active profile selection round-trips")
    func activeProfileRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileRuntimePreferencesStore(directoryURL: directory)
        try await store.savePreferences(
            RuntimePreferences(activeProfileIdentifier: "minecraft-competitive")
        )

        #expect(try await store.loadPreferences().activeProfileIdentifier == "minecraft-competitive")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-runtime-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
