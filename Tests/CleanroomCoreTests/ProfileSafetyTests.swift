import Foundation
import Testing

@testable import CleanroomCore

@Suite("Phantom Forces mutation boundary")
struct ProfileSafetyTests {
    @Test("network infrastructure remains operator-controlled")
    func networkInfrastructureIsNeverManaged() {
        let profile = CleanroomProfile.phantomForces()
        let mutationIdentifiers =
            profile.applications.flatMap { [$0.bundleIdentifier, $0.executableName] }
            + profile.services.map(\.label)
            + profile.processes.flatMap { [$0.executableName] + $0.relaunchCommand }
            + profile.preferences.flatMap { [$0.domain, $0.key] }
        let forbiddenNetworkTerms = [
            "vpn", "tailscale", "mullvad", "wireguard", "little snitch",
            "littlesnitch", "networkextension", "firewall", "packetfilter",
        ]

        #expect(
            mutationIdentifiers.allSatisfy { identifier in
                forbiddenNetworkTerms.allSatisfy {
                    !identifier.localizedCaseInsensitiveContains($0)
                }
            }
        )
        #expect(
            Set(profile.services.map(\.label)) == [
                "org.nix-community.home.skhd",
                "org.nix-community.home.yabai",
            ])
    }

    @Test("built-in profiles have unique identities and trigger bundle IDs")
    func builtInProfilesAreDistinct() {
        let profiles = CleanroomProfile.builtIn()

        #expect(profiles.count >= 2)
        #expect(Set(profiles.map(\.identifier)).count == profiles.count)
        #expect(Set(profiles.map(\.triggerBundleIdentifier)).count == profiles.count)
    }

    @Test("profile validation previews every mutation and rejects infrastructure targets")
    func profileValidationIsFailClosed() {
        let safe = CleanroomProfile.phantomForces()
        let safeReport = safe.validationReport()
        #expect(safeReport.isValid)
        #expect(
            safeReport.mutations.count
                == safe.applications.count + safe.services.count + safe.processes.count
                + safe.preferences.count
        )

        let unsafe = CleanroomProfile(
            identifier: "unsafe",
            name: "Unsafe",
            triggerBundleIdentifier: "com.example.Game",
            applications: [
                ManagedApplication(
                    name: "VPN",
                    bundleIdentifier: "net.tailscale.ipn.macos",
                    executableName: "Tailscale"
                )
            ],
            services: [],
            processes: [],
            preferences: []
        )
        #expect(!unsafe.validationReport().isValid)
        #expect(unsafe.validationReport().errors.contains { $0.contains("infrastructure") })
    }

    @Test("validated custom profiles persist with private permissions")
    func customProfileRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-profile-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileProfileStore(directoryURL: directory)
        let template = CleanroomProfile.phantomForces()
        let custom = CleanroomProfile(
            identifier: "custom-test",
            name: "Custom test",
            triggerBundleIdentifier: "com.example.Game",
            applications: template.applications,
            services: template.services,
            processes: template.processes,
            preferences: template.preferences
        )

        try await store.saveProfiles([custom])

        #expect(try await store.loadProfiles() == [custom])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.profilesURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    @Test("versioned profile import previews mutation additions before saving")
    func profileImportPreviewShowsDiff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-profile-import-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = CleanroomProfile.phantomForces()
        let original = CleanroomProfile(
            identifier: "custom-import-test",
            name: "Import test",
            triggerBundleIdentifier: "com.example.Game",
            applications: [],
            services: [],
            processes: [],
            preferences: []
        )
        let updated = CleanroomProfile(
            identifier: original.identifier,
            name: original.name,
            triggerBundleIdentifier: original.triggerBundleIdentifier,
            applications: [template.applications[0]],
            services: [],
            processes: [],
            preferences: []
        )
        let engine = CleanroomEngine(
            profile: template,
            profileStore: FileProfileStore(directoryURL: directory),
            system: ImportTestSystem(),
            journalStore: ImportTestJournalStore()
        )
        _ = try await engine.upsertProfile(original)
        let exported = try await engine.exportProfile(identifier: original.identifier)
        let exportDocument = try JSONDecoder().decode(ProfileTransferDocument.self, from: exported)
        #expect(exportDocument.schemaVersion == ProfileTransferDocument.currentSchemaVersion)
        #expect(exportDocument.profile == original)
        let data = try JSONEncoder().encode(ProfileTransferDocument(profile: updated))

        let preview = try await engine.previewProfileImport(data)

        #expect(preview.canImport)
        #expect(preview.addedMutations.map(\.target) == [template.applications[0].bundleIdentifier])
        #expect(preview.removedMutations.isEmpty)

        let unsupported = try JSONEncoder().encode(
            ProfileTransferDocument(schemaVersion: 99, profile: updated)
        )
        await #expect(throws: CleanroomError.self) {
            try await engine.previewProfileImport(unsupported)
        }
    }
}

private struct ImportTestSystem: CleanroomSystemControlling {
    func probeTrigger() -> TriggerProbe { TriggerProbe(state: .stopped) }
    func captureSnapshot(for profile: CleanroomProfile) -> SystemSnapshot {
        SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )
    }
    func apply(profile: CleanroomProfile) -> [ActionResult] { [] }
    func verifyApplied(profile: CleanroomProfile) -> [ActionResult] { [] }
    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) -> [ActionResult] { [] }
    func preflight(profile: CleanroomProfile) -> PreflightReport { PreflightReport(findings: []) }
}

private actor ImportTestJournalStore: RecoveryJournalPersisting {
    func journalExists() -> Bool { false }
    func loadJournal() -> RecoveryJournal? { nil }
    func saveJournal(_ journal: RecoveryJournal) {}
    func clearJournal() {}
}
