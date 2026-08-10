import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("macOS preflight fail-safe reporting")
struct MacSystemControllerPreflightTests {
    @Test("failed readiness probes become explicit unknown findings")
    func failedProbesCannotReportReady() async {
        let controller = MacSystemController(
            commands: FailedPreflightCommandRunner(),
            applications: PreflightApplicationManager()
        )
        let profile = CleanroomProfile(
            name: "test",
            applications: [],
            services: [],
            processes: [],
            preferences: []
        )

        let report = await controller.preflight(profile: profile)
        let identifiers = Set(report.findings.map(\.id))

        #expect(
            identifiers.isSuperset(of: [
                "time-machine-unknown",
                "pointer-scan-unknown",
                "vpn-scan-unknown",
                "route-scan-unknown",
                "power-source-unknown",
                "power-profile-unknown",
            ])
        )
        #expect(!identifiers.contains("ready"))
        #expect(report.highestSeverity >= .warning)
        #expect(report.probes?.count == 7)
        #expect(report.probes?.contains(where: { $0.state == .incomplete }) == true)
        #expect(!report.isFreshAndComplete())
    }

    @Test("Low Power Mode is read only from the active power profile")
    func lowPowerModeUsesActiveProfile() {
        let custom = """
            Battery Power:
             lowpowermode 1
            AC Power:
             lowpowermode 0
            """

        #expect(
            MacSystemController.activePowerSource(
                from: "Now drawing from 'AC Power'\n"
            ) == "AC Power"
        )
        #expect(
            MacSystemController.lowPowerModeEnabled(
                in: custom,
                activePowerSource: "AC Power"
            ) == false
        )
        #expect(
            MacSystemController.lowPowerModeEnabled(
                in: custom,
                activePowerSource: "Battery Power"
            ) == true
        )
    }
}

private actor FailedPreflightCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/bin/launchctl" {
            return result(executable, arguments, exitCode: 113, error: "Could not find service")
        }
        if executable == "/bin/ps" {
            return result(executable, arguments, exitCode: 0)
        }
        if executable == "/usr/bin/pgrep" {
            return result(executable, arguments, exitCode: 1)
        }
        return result(executable, arguments, exitCode: 1, error: "probe failed")
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        result(executable, arguments, exitCode: 1, error: "unused")
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

private actor PreflightApplicationManager: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe { ApplicationProbe(state: .stopped) }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .skipped, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .succeeded, detail: "started")
    }
}
