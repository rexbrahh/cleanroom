import Testing

@testable import CleanroomApp

@Suite("Agent liveness repair policy")
struct AgentLivenessRepairPolicyTests {
    @Test("automatic connection failure cannot authorize destructive replacement")
    func automaticFailureIsNonDestructive() {
        #expect(!AgentLivenessRepairTrigger.automaticFailure.permitsDestructiveReplacement)
        #expect(AgentLivenessRepairTrigger.userRequestedReplacement.permitsDestructiveReplacement)
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
