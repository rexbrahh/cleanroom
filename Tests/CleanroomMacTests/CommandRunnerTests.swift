import Foundation
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

    @Test("a fast command exits before its watchdog")
    func fastExit() async {
        let started = ContinuousClock.now
        let result = await LocalCommandRunner().run("/usr/bin/true", arguments: [], timeout: 1)

        #expect(result.succeeded)
        #expect(!result.timedOut)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test("a timed out command is terminated and classified")
    func timeout() async {
        let started = ContinuousClock.now
        let result = await LocalCommandRunner().run("/bin/sleep", arguments: ["5"], timeout: 0.1)

        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("a launch failure is returned without waiting for a watchdog")
    func launchFailure() async {
        let started = ContinuousClock.now
        let result = await LocalCommandRunner().run(
            "/definitely/missing/cleanroom-command",
            arguments: [],
            timeout: 1
        )

        #expect(result.launchError != nil)
        #expect(!result.timedOut)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test("standard output is captured completely")
    func standardOutput() async {
        let result = await LocalCommandRunner().run(
            "/usr/bin/printf",
            arguments: ["cleanroom-output"],
            timeout: 1
        )

        #expect(result.succeeded)
        #expect(result.standardOutput == "cleanroom-output")
        #expect(result.standardError.isEmpty)
    }

    @Test("standard error and non-zero exit are preserved")
    func standardError() async {
        let result = await LocalCommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf cleanroom-error >&2; exit 7"],
            timeout: 1
        )

        #expect(result.exitCode == 7)
        #expect(result.standardError == "cleanroom-error")
        #expect(!result.succeeded)
    }
}
