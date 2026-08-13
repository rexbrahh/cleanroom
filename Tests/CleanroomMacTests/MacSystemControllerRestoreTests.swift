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

    @Test("restore independently verifies every saved component type")
    func restoredComponentsAreVerified() async {
        let application = ManagedApplication(
            name: "Test App",
            bundleIdentifier: "com.example.test-app",
            executableName: "Test App"
        )
        let service = ManagedService(
            name: "Test Service",
            label: "com.example.test-service",
            propertyListURL: URL(fileURLWithPath: "/tmp/com.example.test-service.plist")
        )
        let process = ManagedProcess(
            name: "Test Process",
            executableName: "test-process",
            relaunchCommand: ["/usr/bin/true"]
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [application],
            services: [service],
            processes: [process],
            preferences: []
        )
        let controller = MacSystemController(
            commands: AlwaysRunningCommandRunner(),
            applications: RunningApplicationManager()
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [service.label],
            activeApplicationBundleIdentifiers: [application.bundleIdentifier],
            activeProcessNames: [process.executableName],
            preferences: []
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            Set(results.filter { $0.action.hasPrefix("verify restored ") }.map(\.action)) == [
                "verify restored service",
                "verify restored application",
                "verify restored process",
            ]
        )
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("a successful launch result cannot hide a failed final application probe")
    func finalApplicationProbeBlocksCompletion() async {
        let application = ManagedApplication(
            name: "Test App",
            bundleIdentifier: "com.example.test-app",
            executableName: "Test App"
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [application],
            services: [],
            processes: [],
            preferences: []
        )
        let controller = MacSystemController(
            commands: AlwaysRunningCommandRunner(),
            applications: SuccessfulStartWithoutRunningApplicationManager()
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [application.bundleIdentifier],
            activeProcessNames: [],
            preferences: []
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            results.contains {
                $0.action == "verify restored application" && $0.outcome == .failed
            }
        )
    }

    @Test("snapshot and restore preserve application and process provenance")
    func applicationAndProcessProvenanceRoundTrips() async throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Test App.app")
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/Test App")
        let manager = ProvenanceApplicationManager(
            probe: ApplicationProbe(
                state: .running,
                instances: [
                    ApplicationInstanceIdentity(
                        processIdentifier: 123,
                        bundleURL: bundleURL,
                        executableURL: executableURL
                    )
                ]
            )
        )
        let commands = ProcessIdentityCommandRunner(processIdentifier: 321)
        let processExecutableURL = URL(fileURLWithPath: "/usr/local/bin/test-process")
        let application = ManagedApplication(
            name: "Test App",
            bundleIdentifier: "com.example.test-app",
            executableName: "Test App"
        )
        let process = ManagedProcess(
            name: "Test Process",
            executableName: "test-process",
            relaunchCommand: ["/usr/bin/true"]
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [application],
            services: [],
            processes: [process],
            preferences: []
        )
        let controller = MacSystemController(commands: commands, applications: manager)

        let snapshot = try await controller.captureSnapshot(for: profile)

        #expect(
            snapshot.applications == [
                StoredApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifiers: [123],
                    bundleURLs: [bundleURL],
                    executableURLs: [executableURL]
                )
            ]
        )
        #expect(
            snapshot.processes == [
                StoredProcess(
                    executableName: process.executableName,
                    processIdentifiers: [321],
                    executableURLs: [processExecutableURL]
                )
            ]
        )

        _ = await controller.restore(snapshot: snapshot, profile: profile)
        #expect(await manager.receivedSavedState == snapshot.applications.first)
    }

    @Test("an independently relaunched process is identified in restore results")
    func independentProcessRelaunchIsIdentified() async {
        let process = ManagedProcess(
            name: "Test Process",
            executableName: "test-process",
            relaunchCommand: ["/usr/bin/true"]
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [process],
            preferences: []
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [process.executableName],
            preferences: [],
            processes: [
                StoredProcess(executableName: process.executableName, processIdentifiers: [321])
            ]
        )
        let controller = MacSystemController(
            commands: ProcessIdentityCommandRunner(processIdentifier: 999),
            applications: StoppedApplicationManager()
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            results.contains {
                $0.action == "restore process"
                    && $0.outcome == .warning
                    && $0.detail.contains("independently relaunched as PID [999]")
            }
        )
    }

    @Test("a same-named process from a different executable blocks restoration")
    func differentProcessExecutableIsRejected() async {
        let process = ManagedProcess(
            name: "Test Process",
            executableName: "test-process",
            relaunchCommand: ["/usr/bin/true"]
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [process],
            preferences: []
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [process.executableName],
            preferences: [],
            processes: [
                StoredProcess(
                    executableName: process.executableName,
                    processIdentifiers: [321],
                    executableURLs: [URL(fileURLWithPath: "/usr/local/bin/test-process")]
                )
            ]
        )
        let controller = MacSystemController(
            commands: ProcessIdentityCommandRunner(
                processIdentifier: 999,
                executablePath: "/tmp/unrelated/test-process"
            ),
            applications: StoppedApplicationManager()
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            results.contains {
                $0.action == "restore process"
                    && $0.outcome == .failed
                    && $0.detail.contains("different executable")
            }
        )
        #expect(
            results.contains {
                $0.action == "verify restored process"
                    && $0.outcome == .failed
                    && $0.detail.contains("different executable")
            }
        )
    }

    @Test("a symlink to the saved process executable is accepted")
    func processExecutableSymlinkIsAccepted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("borders-real")
        let symlink = directory.appendingPathComponent("borders")
        try Data().write(to: executable)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

        let process = ManagedProcess(
            name: "JankyBorders",
            executableName: "borders",
            relaunchCommand: [symlink.path]
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [process],
            preferences: []
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [process.executableName],
            preferences: [],
            processes: [
                StoredProcess(
                    executableName: process.executableName,
                    processIdentifiers: [321],
                    executableURLs: [executable]
                )
            ]
        )
        let controller = MacSystemController(
            commands: ProcessIdentityCommandRunner(
                processIdentifier: 999,
                executablePath: symlink.path
            ),
            applications: StoppedApplicationManager()
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
        #expect(
            results.contains {
                $0.action == "verify restored process"
                    && $0.outcome == .succeeded
                    && $0.detail.contains("executable provenance verified")
            }
        )
    }

    @Test("a running service postcondition wins over a racing bootstrap error")
    func serviceRestoreUsesRunningPostcondition() async throws {
        let propertyListURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-service-\(UUID().uuidString).plist")
        try Data("plist".utf8).write(to: propertyListURL)
        defer { try? FileManager.default.removeItem(at: propertyListURL) }
        let service = ManagedService(
            name: "Test Service",
            label: "com.example.test-service",
            propertyListURL: propertyListURL
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [service],
            processes: [],
            preferences: []
        )
        let controller = MacSystemController(
            commands: ServiceBootstrapCommandRunner(postcondition: .running),
            applications: StoppedApplicationManager()
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [service.label],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            results.contains {
                $0.action == "restore service"
                    && $0.outcome == .succeeded
                    && $0.detail.contains("despite bootstrap reporting")
            }
        )
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("an unknown service postcondition remains blocking")
    func unknownServicePostconditionBlocksRestore() async throws {
        let propertyListURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-service-\(UUID().uuidString).plist")
        try Data("plist".utf8).write(to: propertyListURL)
        defer { try? FileManager.default.removeItem(at: propertyListURL) }
        let service = ManagedService(
            name: "Test Service",
            label: "com.example.test-service",
            propertyListURL: propertyListURL
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [service],
            processes: [],
            preferences: []
        )
        let controller = MacSystemController(
            commands: ServiceBootstrapCommandRunner(postcondition: .unknown),
            applications: StoppedApplicationManager()
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [service.label],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(
            results.contains {
                $0.action == "restore service" && $0.outcome == .unknown
            }
        )
        #expect(results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("a snapshot missing a profile preference is rejected before mutation")
    func missingProfilePreferenceBlocksRestore() async {
        let preference = PreferenceAction(
            domain: "NSGlobalDomain",
            key: "test",
            kind: .boolean,
            activeValue: "true"
        )
        let profile = testProfile(preference: preference)
        let commands = CountingCommandRunner()
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager()
        )
        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )

        let results = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(results.count == 1)
        #expect(results.first?.action == "validate recovery snapshot")
        #expect(results.first?.outcome == .failed)
        #expect(results.first?.detail.contains("missing NSGlobalDomain:test") == true)
        #expect(await commands.calls == 0)
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

private actor RunningApplicationManager: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe {
        ApplicationProbe(state: .running, processIdentifier: 42)
    }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .succeeded, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .skipped, detail: "running")
    }
}

private actor SuccessfulStartWithoutRunningApplicationManager: ApplicationManaging {
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

private actor AlwaysRunningCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/usr/bin/pgrep" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "42\n"
            )
        }
        if executable == "/bin/ps", arguments.contains("comm=") {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "/usr/local/bin/test-process\n"
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }
}

private actor ProvenanceApplicationManager: ApplicationManaging {
    private let probeValue: ApplicationProbe
    private(set) var receivedSavedState: StoredApplication?

    init(probe: ApplicationProbe) {
        probeValue = probe
    }

    func probe(bundleIdentifier: String) -> ApplicationProbe {
        probeValue
    }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .succeeded, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .skipped, detail: "running")
    }

    func start(
        bundleIdentifier: String,
        displayName: String,
        savedState: StoredApplication
    ) -> ActionResult {
        receivedSavedState = savedState
        return ActionResult(
            action: "restore application",
            target: displayName,
            outcome: .warning,
            detail: "provenance received"
        )
    }
}

private actor ProcessIdentityCommandRunner: CommandRunning {
    private let processIdentifier: Int32
    private let executablePath: String

    init(
        processIdentifier: Int32,
        executablePath: String = "/usr/local/bin/test-process"
    ) {
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/usr/bin/pgrep" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "\(processIdentifier)\n"
            )
        }
        if executable == "/bin/ps", arguments.contains("comm=") {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "\(executablePath)\n"
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            standardOutput: "\(processIdentifier)"
        )
    }
}

private actor CountingCommandRunner: CommandRunning {
    private(set) var calls = 0

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls += 1
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        calls += 1
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }
}

private actor ServiceBootstrapCommandRunner: CommandRunning {
    private let postcondition: ProbeState
    private var managedPrints = 0

    init(postcondition: ProbeState) {
        self.postcondition = postcondition
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        guard executable == "/bin/launchctl" else {
            return result(executable, arguments, exitCode: 0)
        }
        if arguments.contains("bootstrap") {
            return result(executable, arguments, exitCode: 5, error: "Bootstrap failed: 5")
        }
        if arguments.last?.hasSuffix(MacSystemController.legacyAgentLabel) == true {
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
        }
        managedPrints += 1
        if managedPrints == 1 {
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
        }
        switch postcondition {
        case .running:
            return result(executable, arguments, exitCode: 0)
        case .stopped:
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
        case .unknown:
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: -1,
                timedOut: true
            )
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
