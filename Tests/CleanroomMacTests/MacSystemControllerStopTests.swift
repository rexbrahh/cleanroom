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
            applications: StoppedApplicationManager()
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

    @Test("defaults read retries transient cfprefsd failures")
    func defaultsReadRetriesTransientFailures() async {
        let commands = FlakyDefaultsCommandRunner(failuresBeforeSuccess: 2)
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
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: [preference]
        )

        let snapshot = try? await controller.captureSnapshot(for: profile)

        #expect(snapshot?.preferences.first?.wasPresent == true)
        #expect(snapshot?.preferences.first?.value == "0")
        let readCalls = await commands.calls.filter { $0.contains("read") }
        #expect(readCalls.count == 3)
    }

    @Test("a missing defaults domain counts as key absence")
    func missingDomainMeansAbsentKey() async throws {
        let commands = MissingDomainDefaultsCommandRunner()
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
}

/// Simulates the JankyBorders race: the process is present for the first
/// probe, then vanishes on its own, so every pkill exits 1 ("no match").
private actor VanishingProcessCommandRunner: CommandRunning {
    private var pgrepCalls = 0

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        switch executable {
        case "/usr/bin/pgrep":
            pgrepCalls += 1
            return result(executable, arguments, exitCode: pgrepCalls == 1 ? 0 : 1)
        case "/usr/bin/pkill":
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

/// Simulates transient cfprefsd contention: the first N reads exit 255, then
/// the read succeeds.
private actor FlakyDefaultsCommandRunner: CommandRunning {
    private(set) var calls: [[String]] = []
    private var failuresRemaining: Int

    init(failuresBeforeSuccess: Int) {
        failuresRemaining = failuresBeforeSuccess
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append(arguments)
        if arguments.first == "read", failuresRemaining > 0 {
            failuresRemaining -= 1
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 255,
                standardError: "Could not write domain; exiting"
            )
        }
        if arguments.first == "read" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "0\n"
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }
}

/// Simulates `defaults read` against a domain that does not exist at all.
private actor MissingDomainDefaultsCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        if arguments.first == "read" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                standardError: "Domain (com.apple.dock) not found.\nDefaults have not been changed."
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 0)
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
