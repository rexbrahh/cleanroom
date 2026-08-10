import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("macOS stop and defaults robustness")
struct MacSystemControllerStopTests {
    @Test("stop process succeeds when the process exits on its own during termination")
    func stopProcessIsPostconditionDriven() async {
        let commands = VanishingProcessCommandRunner()
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            userIdentifier: 501
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [
                ManagedProcess(name: "JankyBorders", executableName: "borders", relaunchCommand: ["borders"])
            ],
            preferences: []
        )

        let results = await controller.apply(profile: profile)

        let stopResults = results.filter { $0.action == "stop process" }
        #expect(stopResults.count == 1)
        #expect(stopResults.first?.outcome == .succeeded)
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
        #expect(await commands.processQueries.allSatisfy { $0.contains("-U") && $0.contains("501") })
        #expect(await commands.signalQueries.allSatisfy { $0.contains("-U") && $0.contains("501") })
    }

    @Test("stop service succeeds when bootout reports the service already unloaded")
    func stopServiceIsPostconditionDriven() async {
        let commands = UnloadingServiceCommandRunner()
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager()
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [
                ManagedService(
                    name: "skhd",
                    label: "org.test.skhd",
                    propertyListURL: URL(fileURLWithPath: "/tmp/org.test.skhd.plist")
                )
            ],
            processes: [],
            preferences: []
        )

        let results = await controller.apply(profile: profile)

        let stopResults = results.filter { $0.action == "stop service" }
        #expect(stopResults.count == 1)
        #expect(stopResults.first?.outcome == .succeeded)
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("preference writes retry transient cfprefsd failures")
    func defaultsWriteRetriesTransientFailures() async {
        let state = PreferenceState(initial: [:])
        let commands = FlakyWriteCommandRunner(state: state, failuresBeforeSuccess: 2)
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
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [preference]
        )

        let results = await controller.apply(profile: profile)

        let applyResults = results.filter { $0.action == "apply preference" }
        #expect(applyResults.first?.outcome == .succeeded)
        let writeCalls = await commands.calls.filter { $0.first == "write" }
        #expect(writeCalls.count == 3)
    }

    @Test("a missing preference domain counts as key absence")
    func missingDomainMeansAbsentKey() async throws {
        let state = PreferenceState(initial: [:])
        let controller = MacSystemController(
            commands: FlakyWriteCommandRunner(state: state, failuresBeforeSuccess: 0),
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
        )
        let preference = PreferenceAction(
            domain: "com.apple.dock",
            key: "wvous-br-modifier",
            kind: .integer,
            activeValue: "0"
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [preference]
        )

        let snapshot = try await controller.captureSnapshot(for: profile)

        #expect(snapshot.preferences.first?.wasPresent == false)
    }

    @Test("no-op apply skips writes and never restarts synchronized processes")
    func noOpApplySkipsWritesAndSynchronize() async {
        let preference = PreferenceAction(
            domain: "com.apple.dock",
            key: "wvous-br-corner",
            kind: .integer,
            activeValue: "1",
            synchronizeProcess: "Dock"
        )
        let state = PreferenceState(initial: [
            PreferenceKey("com.apple.dock", "wvous-br-corner"): "1"
        ])
        let commands = FlakyWriteCommandRunner(state: state, failuresBeforeSuccess: 0)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [preference]
        )

        let results = await controller.apply(profile: profile)

        let applyResults = results.filter { $0.action == "apply preference" }
        #expect(applyResults.first?.outcome == .skipped)
        let calls = await commands.calls
        #expect(!calls.contains { $0.first == "write" || $0.first == "delete" })
        #expect(await commands.synchronizeCalls == 0)
        #expect(!results.contains { $0.action == "synchronize preferences" })
    }

    @Test("failed preference writes do not restart synchronized processes")
    func failedWriteSkipsSynchronize() async {
        let state = PreferenceState(initial: [:])
        let commands = FlakyWriteCommandRunner(state: state, failuresBeforeSuccess: 3)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [
                PreferenceAction(
                    domain: "com.apple.dock",
                    key: "wvous-br-corner",
                    kind: .integer,
                    activeValue: "1",
                    synchronizeProcess: "Dock"
                )
            ]
        )

        let results = await controller.apply(profile: profile)

        #expect(results.first { $0.action == "apply preference" }?.outcome == .failed)
        #expect(await commands.synchronizeCalls == 0)
        #expect(!results.contains { $0.action == "synchronize preferences" })
    }

    @Test("active boolean writes use canonical defaults syntax")
    func activeBooleanIsCanonicalized() async {
        let state = PreferenceState(initial: [
            PreferenceKey("NSGlobalDomain", "com.apple.mouse.linear"): "0"
        ])
        let commands = FlakyWriteCommandRunner(state: state, failuresBeforeSuccess: 0)
        let controller = MacSystemController(
            commands: commands,
            applications: StoppedApplicationManager(),
            preferences: FakePreferenceReader(state: state)
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [
                PreferenceAction(
                    domain: "NSGlobalDomain",
                    key: "com.apple.mouse.linear",
                    kind: .boolean,
                    activeValue: "1"
                )
            ]
        )

        let results = await controller.apply(profile: profile)
        let calls = await commands.calls

        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
        #expect(
            calls.contains([
                "write", "NSGlobalDomain", "com.apple.mouse.linear", "-bool", "true",
            ])
        )
    }

    @Test("unknown legacy watcher ownership blocks mutation and readiness")
    func unknownLegacyWatcherFailsClosed() async {
        let commands = UnknownLegacyCommandRunner()
        let applications = MutationCountingApplicationManager()
        let controller = MacSystemController(commands: commands, applications: applications)
        let profile = CleanroomProfile(
            name: "test",
            applications: [
                ManagedApplication(
                    name: "Test App",
                    bundleIdentifier: "com.example.test-app",
                    executableName: "Test App"
                )
            ],
            services: [
                ManagedService(
                    name: "Test Service",
                    label: "com.example.test-service",
                    propertyListURL: URL(fileURLWithPath: "/tmp/com.example.test-service.plist")
                )
            ],
            processes: [
                ManagedProcess(
                    name: "Test Process",
                    executableName: "test-process",
                    relaunchCommand: ["/usr/bin/true"]
                )
            ],
            preferences: []
        )

        let apply = await controller.apply(profile: profile)

        #expect(apply.count == 1)
        #expect(apply.first?.action == "safety check")
        #expect(apply.first?.outcome == .unknown)
        #expect(await commands.calls == 1)
        #expect(await applications.stopCalls == 0)

        let emptyProfile = CleanroomProfile(
            name: "empty",
            applications: [],
            services: [],
            processes: [],
            preferences: []
        )
        let verification = await controller.verifyApplied(profile: emptyProfile)
        #expect(verification.first?.action == "verify legacy watcher")
        #expect(verification.first?.outcome == .unknown)

        let preflight = await controller.preflight(profile: emptyProfile)
        #expect(
            preflight.findings.contains {
                $0.id == "legacy-agent-unknown" && $0.severity == .critical
            }
        )
    }
}

/// Simulates the JankyBorders race: the process is present for the first
/// probe, then vanishes on its own, so every pkill exits 1 ("no match").
private actor VanishingProcessCommandRunner: CommandRunning {
    private var pgrepCalls = 0
    private(set) var processQueries: [[String]] = []
    private(set) var signalQueries: [[String]] = []

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        switch executable {
        case "/usr/bin/pgrep":
            processQueries.append(arguments)
            pgrepCalls += 1
            return result(
                executable,
                arguments,
                exitCode: pgrepCalls == 1 ? 0 : 1,
                output: pgrepCalls == 1 ? "42\n" : ""
            )
        case "/bin/ps":
            return result(
                executable,
                arguments,
                exitCode: 0,
                output: "/usr/local/bin/borders\n"
            )
        case "/usr/bin/pkill":
            signalQueries.append(arguments)
            return result(executable, arguments, exitCode: 1, error: "pkill: signalling pid 0: No such process")
        case "/bin/launchctl":
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
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

/// Simulates a service that unloads between the probe and bootout: bootout
/// exits 5, but the follow-up print shows the service is gone.
private actor UnloadingServiceCommandRunner: CommandRunning {
    private var managedPrints = 0

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        guard executable == "/bin/launchctl" else {
            return result(executable, arguments, exitCode: 0)
        }
        if arguments.contains("print") {
            let label = arguments.last ?? ""
            if label.hasSuffix(MacSystemController.legacyAgentLabel) {
                return result(executable, arguments, exitCode: 113, error: "Could not find service")
            }
            managedPrints += 1
            return result(executable, arguments, exitCode: managedPrints == 1 ? 0 : 113)
        }
        if arguments.contains("bootout") {
            return result(executable, arguments, exitCode: 5, error: "Boot-out failed: 5: Input/output error")
        }
        return result(executable, arguments, exitCode: 0)
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

/// Simulates transient cfprefsd write contention: the first N writes exit
/// 255, then writes succeed and mirror into the shared state.
private actor FlakyWriteCommandRunner: CommandRunning {
    private(set) var calls: [[String]] = []
    private(set) var synchronizeCalls = 0
    private let state: PreferenceState
    private var failuresRemaining: Int

    init(state: PreferenceState, failuresBeforeSuccess: Int) {
        self.state = state
        failuresRemaining = failuresBeforeSuccess
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        calls.append(arguments)
        switch executable {
        case "/bin/launchctl":
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
        case "/usr/bin/defaults":
            if arguments.first == "write" {
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    return result(executable, arguments, exitCode: 255, error: "Could not write domain; exiting")
                }
                await state.write(PreferenceKey(arguments[1], arguments[2]), value: arguments[4])
            }
            if arguments.first == "delete" {
                await state.delete(PreferenceKey(arguments[1], arguments[2]))
            }
            return result(executable, arguments, exitCode: 0)
        case "/usr/bin/killall":
            synchronizeCalls += 1
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

private actor UnknownLegacyCommandRunner: CommandRunning {
    private(set) var calls = 0

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls += 1
        if executable == "/bin/launchctl",
            arguments.last?.hasSuffix(MacSystemController.legacyAgentLabel) == true
        {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: -1,
                timedOut: true
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 1)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        calls += 1
        return CommandResult(executable: executable, arguments: arguments, exitCode: 1)
    }
}

private actor MutationCountingApplicationManager: ApplicationManaging {
    private(set) var stopCalls = 0

    func probe(bundleIdentifier: String) -> ApplicationProbe {
        ApplicationProbe(state: .stopped)
    }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        stopCalls += 1
        return ActionResult(action: "stop", target: displayName, outcome: .succeeded, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .succeeded, detail: "started")
    }
}
