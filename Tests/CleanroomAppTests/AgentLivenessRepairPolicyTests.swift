import Testing

@testable import CleanroomApp

@Suite("Agent liveness repair policy")
struct AgentLivenessRepairPolicyTests {
    @Test("automatic connection failure cannot authorize destructive replacement")
    func automaticFailureIsNonDestructive() {
        #expect(!AgentLivenessRepairTrigger.automaticFailure.permitsDestructiveReplacement)
        #expect(AgentLivenessRepairTrigger.installerAuthorizedReplacement.permitsDestructiveReplacement)
        #expect(AgentLivenessRepairTrigger.userRequestedReplacement.permitsDestructiveReplacement)
    }

    @Test("installer authorization is scoped to the installed build")
    func installerAuthorizationMatchesBuild() {
        #expect(
            CleanroomViewModel.installerReplacementIsAuthorized(
                markerBuild: "7\n",
                currentBuild: "7"
            )
        )
        #expect(
            !CleanroomViewModel.installerReplacementIsAuthorized(
                markerBuild: "6",
                currentBuild: "7"
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
