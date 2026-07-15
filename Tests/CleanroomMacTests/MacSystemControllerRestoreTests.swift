import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("macOS preference restoration")
struct MacSystemControllerRestoreTests {
    @Test("saved numeric boolean is written using defaults boolean syntax")
    func numericBooleanIsCanonicalized() async {
        let commands = RestoreCommandRunner(mode: .booleanFalse)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager()
        )
        let preference = PreferenceAction(
            domain: "NSGlobalDomain",
            key: "com.apple.mouse.linear",
            kind: .boolean,
            activeValue: "true"
        )
        let profile = testProfile(preference: preference)
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: [
                StoredPreference(
                    domain: preference.domain,
                    key: preference.key,
                    kind: .boolean,
                    wasPresent: true,
                    value: "0"
                )
            ]
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)
        let calls = await commands.calls

        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
        #expect(
            calls.contains([
                "write", "NSGlobalDomain", "com.apple.mouse.linear", "-bool", "false",
            ])
        )
    }

    @Test("failed delete succeeds when a read confirms the key is absent")
    func absentPreferenceIsVerified() async {
        let commands = RestoreCommandRunner(mode: .absent)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager()
        )
        let preference = PreferenceAction(
            domain: "com.apple.dock",
            key: "wvous-br-modifier",
            kind: .integer,
            activeValue: "0"
        )
        let profile = testProfile(preference: preference)
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: [
                StoredPreference(
                    domain: preference.domain,
                    key: preference.key,
                    kind: .integer,
                    wasPresent: false,
                    value: nil
                )
            ]
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
        #expect(
            results.contains(where: {
                $0.action == "restore preference" && $0.outcome == .succeeded
            })
        )
    }

    private func testProfile(preference: PreferenceAction) -> CleanroomProfile {
        CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [preference]
        )
    }
}

private actor RestoreCommandRunner: CommandRunning {
    enum Mode: Sendable {
        case booleanFalse
        case absent
    }

    private(set) var calls: [[String]] = []
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append(arguments)
        switch (mode, arguments.first) {
        case (.booleanFalse, "write"):
            return result(executable, arguments, exitCode: 0)
        case (.booleanFalse, "read"):
            return result(executable, arguments, exitCode: 0, output: "0\n")
        case (.absent, "delete"):
            return result(
                executable,
                arguments,
                exitCode: 1,
                error: "Domain (com.apple.dock) not found."
            )
        case (.absent, "read"):
            return result(executable, arguments, exitCode: 1, error: "The default does not exist.")
        default:
            return result(executable, arguments, exitCode: 0)
        }
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        result(executable, arguments, exitCode: 0)
    }

    private func result(
        _ executable: String,
        _ arguments: [String],
        exitCode: Int32,
        output: String = "",
        error: String = ""
    ) -> CommandResult {
        CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: exitCode,
            standardOutput: output,
            standardError: error
        )
    }
}

private actor StoppedApplicationManager: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe {
        ApplicationProbe(state: .stopped)
    }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .skipped, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .succeeded, detail: "started")
    }
}
