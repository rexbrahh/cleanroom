import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("Read-only network latency")
struct NetworkLatencyTests {
    @Test("samples only the active gateway with read-only commands")
    func gatewaySamplingIsReadOnly() async {
        let runner = LatencyRunner()
        let controller = MacSystemController(commands: runner, applications: LatencyApplications())

        let report = await controller.sampleNetworkLatency(sampleCount: 5)

        #expect(report.target == "192.0.2.1")
        #expect(report.averageMilliseconds == 2.5)
        #expect(report.jitterMilliseconds == 0.4)
        #expect(report.packetLossPercent == 0)
        #expect(report.readOnly)
        #expect(
            report.commands
                == [
                    CommandObservation(executable: "/sbin/route", arguments: ["-n", "get", "default"]),
                    CommandObservation(
                        executable: "/sbin/ping",
                        arguments: ["-n", "-q", "-c", "5", "-W", "1000", "192.0.2.1"]
                    ),
                ])
        #expect(await runner.executed == report.commands)
    }
}

private actor LatencyRunner: CommandRunning {
    private(set) var executed: [CommandObservation] = []

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        executed.append(CommandObservation(executable: executable, arguments: arguments))
        if executable == "/sbin/route" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "   route to: default\ngateway: 192.0.2.1\n"
            )
        }
        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: 0,
            standardOutput:
                "5 packets transmitted, 5 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 1.0/2.5/4.0/0.4 ms\n"
        )
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 1)
    }
}

private actor LatencyApplications: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe { ApplicationProbe(state: .stopped) }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .skipped, detail: "unused")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .skipped, detail: "unused")
    }
}
