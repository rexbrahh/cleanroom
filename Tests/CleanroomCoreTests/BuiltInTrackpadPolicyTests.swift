import Foundation
import Testing

@testable import CleanroomCore

@Suite("Built-in trackpad suppression policy")
struct BuiltInTrackpadPolicyTests {
    @Test("profile flag off never suppresses")
    func disabledProfileNeverSuppresses() {
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: false,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: false
            )
        )
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: false,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: true
            )
        )
    }

    @Test("missing or unknown pointer leaves the trackpad on")
    func pointerAbsenceFailsOpen() {
        for pointer in [DevicePresence.absent, .unknown] {
            #expect(
                !BuiltInTrackpadPolicy.desiredSuppressed(
                    enabledInProfile: true,
                    lid: .open,
                    externalPointer: pointer,
                    builtInTrackpadPresent: true,
                    currentlySuppressed: false
                )
            )
            #expect(
                !BuiltInTrackpadPolicy.desiredSuppressed(
                    enabledInProfile: true,
                    lid: .open,
                    externalPointer: pointer,
                    builtInTrackpadPresent: true,
                    currentlySuppressed: true
                )
            )
        }
    }

    @Test("closed lid leaves the trackpad on")
    func closedLidDoesNotSuppress() {
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .closed,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: false
            )
        )
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .closed,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: true
            )
        )
    }

    @Test("open lid and present pointer suppress the built-in trackpad")
    func openLidWithPointerSuppresses() {
        #expect(
            BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: false
            )
        )
        #expect(
            BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: true
            )
        )
    }

    @Test("unknown lid keeps the current suppression state when a pointer is present")
    func unknownLidKeepsCurrentState() {
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .unknown,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: false
            )
        )
        #expect(
            BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .unknown,
                externalPointer: .present,
                builtInTrackpadPresent: true,
                currentlySuppressed: true
            )
        )
    }

    @Test("desktop Macs without a built-in trackpad stay unsuppressed")
    func missingBuiltInTrackpadNeverSuppresses() {
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: false,
                currentlySuppressed: false
            )
        )
        #expect(
            !BuiltInTrackpadPolicy.desiredSuppressed(
                enabledInProfile: true,
                lid: .open,
                externalPointer: .present,
                builtInTrackpadPresent: false,
                currentlySuppressed: true
            )
        )
    }

    @Test("verify outcomes distinguish matched, repairable, and permission-denied states")
    func verifyOutcomes() {
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: true,
                currentlySuppressed: true,
                listenEventAccessGranted: true
            ) == .succeeded
        )
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: false,
                currentlySuppressed: false,
                listenEventAccessGranted: true
            ) == .skipped
        )
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: true,
                currentlySuppressed: false,
                listenEventAccessGranted: true
            ) == .failed
        )
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: false,
                currentlySuppressed: true,
                listenEventAccessGranted: true
            ) == .failed
        )
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: true,
                currentlySuppressed: false,
                listenEventAccessGranted: false
            ) == .warning
        )
        #expect(
            BuiltInTrackpadPolicy.verifyOutcome(
                desired: false,
                currentlySuppressed: true,
                listenEventAccessGranted: false
            ) == .failed
        )
    }

    @Test("built-in profiles advertise the lid-open trackpad mutation")
    func builtInProfilesIncludeTrackpadMutation() {
        let profile = CleanroomProfile.phantomForces()
        #expect(profile.suppressBuiltInTrackpadWhenLidOpen)
        let preview = profile.validationReport().mutations.first {
            $0.target == "built-in-trackpad"
        }
        #expect(preview?.action == "suppress built-in trackpad")
        #expect(preview?.detail.contains("lid is open") == true)
    }

    @Test("legacy profile JSON defaults the trackpad flag on")
    func missingFlagDefaultsOn() throws {
        let json = """
            {
              "identifier": "legacy",
              "name": "Legacy",
              "triggerBundleIdentifier": "com.example.Game",
              "applications": [],
              "services": [],
              "processes": [],
              "preferences": [],
              "processCPUWarningPercent": 20,
              "processCPUCriticalPercent": 50,
              "blockAutomaticEntryOnCriticalPreflight": false,
              "targetPolicies": []
            }
            """
        let profile = try JSONDecoder().decode(CleanroomProfile.self, from: Data(json.utf8))
        #expect(profile.suppressBuiltInTrackpadWhenLidOpen)
        #expect(profile.validationReport().mutations.contains { $0.target == "built-in-trackpad" })
    }

    @Test("explicitly disabled flag omits the trackpad mutation")
    func disabledFlagOmitsMutation() {
        let profile = CleanroomProfile(
            name: "No trackpad",
            applications: [],
            services: [],
            processes: [],
            preferences: [],
            suppressBuiltInTrackpadWhenLidOpen: false
        )
        #expect(!profile.suppressBuiltInTrackpadWhenLidOpen)
        #expect(!profile.validationReport().mutations.contains { $0.target == "built-in-trackpad" })
    }
}
