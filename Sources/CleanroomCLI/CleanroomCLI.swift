import ArgumentParser
import CleanroomCore
import CleanroomProtocol
import Foundation

@main
struct CleanroomCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanroomctl",
        abstract: "Control the private Roblox/Phantom Forces Cleanroom agent.",
        version: "3.0.1",
        subcommands: [
            Status.self,
            Enter.self,
            Restore.self,
            Preflight.self,
            Pause.self,
            Resume.self,
            Recover.self,
            Events.self,
            MigrateLegacy.self,
        ],
        defaultSubcommand: Status.self
    )
}

private struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print the complete machine-readable response.")
    var json = false
}

private struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show live agent and cleanroom status.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.status, json: output.json)
    }
}

private struct Enter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Enter or re-enforce the Roblox cleanroom.")
    @Flag(name: .long, help: "Proceed past critical preflight findings.")
    var force = false
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.enter(force: force), json: output.json)
    }
}

private struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore the exact saved desktop and input state.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.restore, json: output.json)
    }
}

private struct Preflight: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run competitive input, load, network, and thermal checks.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.preflight, json: output.json)
    }
}

private struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause automatic transitions without discarding recovery state.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.setPaused(true), json: output.json)
    }
}

private struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume automatic Roblox detection and restoration.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.setPaused(false), json: output.json)
    }
}

private struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent bounded diagnostic events.")
    @Option(name: .shortAndLong, help: "Maximum number of events to return.")
    var limit = 20
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.recentEvents(limit: limit), json: output.json)
    }
}

private struct MigrateLegacy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-legacy",
        abstract: "Restore and retire the old shell watcher while Roblox is closed."
    )
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.migrateLegacy, json: output.json)
    }
}

private struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resolve a degraded session using an explicit recovery action.",
        subcommands: [RetryEntry.self, RetryRestore.self, DiscardJournal.self]
    )

    struct RetryEntry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "retry-entry")
        @OptionGroup var output: OutputOptions
        func run() async throws { try await CLI.run(.recover(.retryEntry), json: output.json) }
    }

    struct RetryRestore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "retry-restore")
        @OptionGroup var output: OutputOptions
        func run() async throws { try await CLI.run(.recover(.retryRestore), json: output.json) }
    }

    struct DiscardJournal: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "discard-journal",
            abstract: "Discard recovery state after manual verification. This can strand settings."
        )
        @Flag(name: .long, help: "Confirm that saved restoration data should be discarded.")
        var confirm = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            guard confirm else {
                throw ValidationError(
                    "Pass --confirm only after manually verifying the restored desktop and input state.")
            }
            try await CLI.run(.recover(.discardJournal), json: output.json)
        }
    }
}

private enum CLI {
    static func run(_ command: AgentCommand, json: Bool) async throws {
        let client = CleanroomAgentClient()
        do {
            let response = try await client.send(command)
            if json {
                let data = try AgentCodec.encode(response)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(render(response.payload))
            }
            if case .transition(let report) = response.payload, report.phase == .degraded {
                throw ExitCode.failure
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            throw CleanroomCLIError.message(
                "Could not reach the Cleanroom agent: \(error.localizedDescription). Open Cleanroom.app once to register it."
            )
        }
    }

    static func render(_ payload: AgentPayload) -> String {
        switch payload {
        case .status(let status):
            var lines = [
                "phase: \(status.phase.rawValue)",
                "roblox: \(status.trigger.state.rawValue)",
                "recovery journal: \(status.journal == nil ? "absent" : "present")",
                "message: \(status.lastMessage)",
            ]
            if let heartbeat = status.heartbeatAt {
                lines.append("heartbeat: \(heartbeat.ISO8601Format())")
            }
            return lines.joined(separator: "\n")
        case .transition(let report):
            var lines = ["phase: \(report.phase.rawValue)", "message: \(report.message)"]
            lines += report.results.map {
                "[\($0.outcome.rawValue)] \($0.action) / \($0.target): \($0.detail)"
            }
            return lines.joined(separator: "\n")
        case .preflight(let report):
            return report.findings.map {
                "[\($0.severity.rawValue)] \($0.category) / \($0.summary): \($0.detail)"
            }.joined(separator: "\n")
        case .events(let reports):
            return reports.map {
                "[\($0.phase.rawValue)] \($0.message)"
            }.joined(separator: "\n")
        case .failure(let message):
            return "error: \(message)"
        }
    }
}

private enum CleanroomCLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}
