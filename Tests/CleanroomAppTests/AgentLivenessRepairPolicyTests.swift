import CleanroomCore
import Foundation
import Testing

@testable import CleanroomApp

@Suite("Agent liveness repair policy")
struct AgentLivenessRepairPolicyTests {
    @Test("a failed live connection cannot be presented as healthy from cached status")
    @MainActor
    func cachedStatusDoesNotMaskConnectionFailure() {
        let model = CleanroomViewModel()
        model.status = CleanroomStatus(
            phase: .idle,
            trigger: TriggerProbe(state: .stopped),
            journal: nil,
            lastMessage: "Roblox is not running.",
            lastResults: [],
            preflight: nil,
            heartbeatAt: Date()
        )
        model.connectionMessage = "Agent unavailable: request timed out"

        #expect(model.agentHealth == .unavailable)
        #expect(!model.setupDoctorState.xpcConnected)
    }

    @Test("automatic connection failure cannot authorize destructive replacement")
    func automaticFailureIsNonDestructive() {
        #expect(!AgentLivenessRepairTrigger.automaticFailure.permitsDestructiveReplacement)
        #expect(AgentLivenessRepairTrigger.installerAuthorizedReplacement.permitsDestructiveReplacement)
        #expect(AgentLivenessRepairTrigger.userRequestedReplacement.permitsDestructiveReplacement)
    }

    @Test("digest change without a journal authorizes helper replacement")
    func digestChangeReplacesWhenIdle() {
        #expect(
            CleanroomViewModel.launchRegistrationTrigger(
                userRequestedReplacement: false,
                installerMarkerAuthorized: false,
                digestChanged: true,
                recoveryJournalExists: false
            ) == .installerAuthorizedReplacement
        )
        #expect(
            CleanroomViewModel.shouldReplaceEnabledAgent(
                triggerPermitsDestructiveReplacement: false,
                digestChanged: true,
                recoveryJournalExists: false
            )
        )
        #expect(
            CleanroomViewModel.launchRegistrationTrigger(
                userRequestedReplacement: false,
                installerMarkerAuthorized: false,
                digestChanged: true,
                recoveryJournalExists: true
            ) == .automaticFailure
        )
        #expect(
            !CleanroomViewModel.shouldReplaceEnabledAgent(
                triggerPermitsDestructiveReplacement: false,
                digestChanged: true,
                recoveryJournalExists: true
            )
        )
    }

    @Test("installer authorization is scoped to the installed build")
    func installerAuthorizationMatchesBuild() {
        #expect(
            CleanroomViewModel.installerReplacementIsAuthorized(
                markerBuild: "8\n",
                currentBuild: "8"
            )
        )
        #expect(
            !CleanroomViewModel.installerReplacementIsAuthorized(
                markerBuild: "6",
                currentBuild: "8"
            )
        )
    }

    @Test("status polling does not consume a newer installer's replacement marker")
    func staleMenuAppDoesNotClearNewerReplacementMarker() {
        let build12 = CleanroomBuildIdentity(version: "3.2.4", build: "12")
        let build13 = CleanroomBuildIdentity(version: "3.2.4", build: "13")
        #expect(
            !CleanroomViewModel.shouldClearInstallerReplacementAuthorization(
                agentBuild: build12,
                currentBuild: build12,
                markerBuild: "13\n"
            )
        )
        #expect(
            CleanroomViewModel.shouldClearInstallerReplacementAuthorization(
                agentBuild: build13,
                currentBuild: build13,
                markerBuild: "13\n"
            )
        )
    }

    @Test("registration and cooldown suppress automatic kickstart")
    func registrationSuppressesAutomaticRepair() {
        #expect(
            !CleanroomViewModel.shouldAttemptAutomaticLivenessRepair(
                registrationInProgress: true,
                elapsedSinceRegistrationRepair: 60
            )
        )
        #expect(
            !CleanroomViewModel.shouldAttemptAutomaticLivenessRepair(
                registrationInProgress: false,
                elapsedSinceRegistrationRepair: 29
            )
        )
        #expect(
            CleanroomViewModel.shouldAttemptAutomaticLivenessRepair(
                registrationInProgress: false,
                elapsedSinceRegistrationRepair: 30
            )
        )
    }

    @Test("setup completion requires registration, XPC, and manual menu confirmation")
    func setupDoctorCompletionGate() {
        #expect(
            !SetupDoctorState(
                agentRegistered: true,
                xpcConnected: true,
                menuItemConfirmed: false
            ).canComplete
        )
        #expect(
            SetupDoctorState(
                agentRegistered: true,
                xpcConnected: true,
                menuItemConfirmed: true
            ).canComplete
        )
    }

    @Test("global hotkeys route through the same agent commands as the UI")
    func globalHotKeyRouting() {
        #expect(GlobalHotKeyAction.status.agentCommand == .status)
        #expect(GlobalHotKeyAction.preflight.agentCommand == .preflight)
        #expect(GlobalHotKeyAction.safeLaunch.agentCommand == .safeLaunch)
        #expect(GlobalHotKeyAction.restore.agentCommand == .restore)
        #expect(GlobalHotKeyAction.togglePause.agentCommand == nil)
        #expect(Set(GlobalHotKeyAction.allCases.map(\.keyCode)).count == 5)
    }
}
