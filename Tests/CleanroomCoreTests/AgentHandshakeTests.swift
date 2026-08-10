import CleanroomCore
import CleanroomProtocol
import Testing

@Suite("Agent capability negotiation")
struct AgentHandshakeTests {
    @Test("every mutating command declares its required capability")
    func mutationCapabilities() {
        #expect(AgentCommand.status.requiredCapability == nil)
        #expect(AgentCommand.preflight.requiredCapability == nil)
        #expect(AgentCommand.enter(force: false).requiredCapability == .enter)
        #expect(AgentCommand.restore.requiredCapability == .restore)
        #expect(AgentCommand.safeLaunch.requiredCapability == .safeLaunch)
        #expect(AgentCommand.setPaused(true).requiredCapability == .pause)
        #expect(AgentCommand.recover(.retryRestore).requiredCapability == .recovery)
        #expect(AgentCommand.saveProfile(.phantomForces()).requiredCapability == .profileEditing)
        #expect(
            AgentCommand.saveDeviceCalibration(DeviceCalibration(hardwareIdentifier: "mac")).requiredCapability
                == .calibration)
        #expect(AgentCommand.migrateLegacy.requiredCapability == .legacyMigration)
    }

    @Test("missing versions or capabilities explain incompatibility")
    func validationFailsClosed() throws {
        let compatible = AgentHandshakeResponse(
            selectedProtocolVersion: AgentHandshakeResponse.currentProtocolVersion,
            capabilities: [.restore]
        )
        try compatible.validate(required: .restore)
        #expect(throws: AgentProtocolError.self) { try compatible.validate(required: .safeLaunch) }
        let incompatible = AgentHandshakeResponse(
            selectedProtocolVersion: nil,
            capabilities: AgentCapability.allCases,
            incompatibility: "no shared version"
        )
        #expect(throws: AgentProtocolError.self) { try incompatible.validate(required: .restore) }
    }
}
