import Testing

@testable import CleanroomMac

@Suite("Command result classification")
struct CommandRunnerTests {
    @Test("only a clean zero exit is successful")
    func successClassification() {
        #expect(CommandResult(executable: "/bin/true", arguments: [], exitCode: 0).succeeded)
        #expect(!CommandResult(executable: "/bin/false", arguments: [], exitCode: 1).succeeded)
        #expect(
            !CommandResult(
                executable: "/bin/true",
                arguments: [],
                exitCode: 0,
                timedOut: true
            ).succeeded)
        #expect(
            !CommandResult(
                executable: "/missing",
                arguments: [],
                exitCode: -1,
                launchError: "missing"
            ).succeeded)
    }
}
