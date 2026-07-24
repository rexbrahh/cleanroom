import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("macOS preference restoration")
struct MacSystemControllerRestoreTests {
    @Test("saved numeric boolean is written using defaults boolean syntax")
    func numericBooleanIsCanonicalized() async {
        let state = PreferenceState(initial: [
            PreferenceKey("NSGlobalDomain", "com.apple.mouse.linear"): "1"
        ])
        let commands = RestoreCommandRunner(state: state)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
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
        let state = PreferenceState(initial: [
            PreferenceKey("com.apple.dock", "wvous-br-modifier"): "3"
        ])
        let commands = RestoreCommandRunner(state: state, deleteFailsAsMissingDomain: true)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
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

struct PreferenceKey: Hashable, Sendable {
    let domain: String
    let key: String

    init(_ domain: String, _ key: String) {
        self.domain = domain
        self.key = key
    }
}

actor PreferenceState {
    private var values: [PreferenceKey: String]

    init(initial: [PreferenceKey: String]) {
        values = initial
    }

    func value(for key: PreferenceKey) -> String? {
        values[key]
    }

    func write(_ key: PreferenceKey, value: String) {
        values[key] = value
    }

    func delete(_ key: PreferenceKey) {
        values.removeValue(forKey: key)
    }
}

actor FakePreferenceReader: PreferenceReading {
    private let state: PreferenceState

    init(state: PreferenceState) {
        self.state = state
    }

    func readStored(_ preference: PreferenceAction) async throws -> StoredPreference {
        let value = await state.value(for: PreferenceKey(preference.domain, preference.key))
        return StoredPreference(
            domain: preference.domain,
            key: preference.key,
            kind: preference.kind,
            wasPresent: value != nil,
            value: value
        )
    }
}

/// Mirrors `defaults` writes and deletes into the shared state so reads after
/// a mutation observe the new value, exactly like cfprefsd.
private actor RestoreCommandRunner: CommandRunning {
    private(set) var calls: [[String]] = []
    private let state: PreferenceState
    private let deleteFailsAsMissingDomain: Bool

    init(state: PreferenceState, deleteFailsAsMissingDomain: Bool = false) {
        self.state = state
        self.deleteFailsAsMissingDomain = deleteFailsAsMissingDomain
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        calls.append(arguments)
        switch arguments.first {
        case "write" where arguments.count >= 5:
            await state.write(
                PreferenceKey(arguments[1], arguments[2]),
                value: arguments[4]
            )
            return result(executable, arguments, exitCode: 0)
        case "delete" where arguments.count >= 3:
            await state.delete(PreferenceKey(arguments[1], arguments[2]))
            if deleteFailsAsMissingDomain {
                return result(
                    executable,
                    arguments,
                    exitCode: 1,
                    error: "Domain (com.apple.dock) not found."
                )
            }
            return result(executable, arguments, exitCode: 0)
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
        error: String = ""
    ) -> CommandResult {
        CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: exitCode,
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
