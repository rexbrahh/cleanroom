import ArgumentParser
import CleanroomCore
import CleanroomMac
import CleanroomProtocol
import Foundation

@main
struct CleanroomCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanroomctl",
        abstract: "Control the private Roblox/Phantom Forces Cleanroom agent.",
        version: CleanroomBuildIdentity.current.description,
        subcommands: [
            Status.self,
            Enter.self,
            Restore.self,
            Launch.self,
            Preflight.self,
            Pause.self,
            Resume.self,
            Incident.self,
            Profiles.self,
            Calibration.self,
            Recover.self,
            Events.self,
            Timeline.self,
            Latency.self,
            Pressure.self,
            Doctor.self,
            Watch.self,
            Receipts.self,
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

private struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save and validate recovery state before opening Roblox."
    )
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.safeLaunch, json: output.json)
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

private struct Timeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show bounded system-only transition performance records."
    )
    @Option(name: .shortAndLong, help: "Maximum number of records to return.")
    var limit = 20
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.performanceTimeline(limit: limit), json: output.json)
    }
}

private struct Latency: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sample latency and jitter to the active default gateway without changing networking."
    )
    @Option(name: .shortAndLong, help: "Number of ICMP samples (1...20).")
    var count = 5
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard (1...20).contains(count) else { throw ValidationError("--count must be 1...20") }
    }

    func run() async throws {
        try await CLI.run(.networkLatency(sampleCount: count), json: output.json)
    }
}

private struct Pressure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read the current macOS thermal and battery state."
    )
    @OptionGroup var output: OutputOptions

    func run() async throws { try await CLI.run(.systemPressure, json: output.json) }
}

private struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose launchd registration, authenticated protocol, heartbeat, and diagnostics health."
    )
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let launchd = await LocalCommandRunner().run(
            "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/com.rex.cleanroom.agent"],
            timeout: 5
        )
        var checks = [
            DoctorCheck(
                id: "registration",
                passed: launchd.succeeded,
                detail: launchd.succeeded ? "launchd registration is present" : "launchd registration is missing"
            )
        ]
        do {
            let client = CleanroomAgentClient()
            let negotiation = try await client.send(.handshake(AgentHandshakeRequest()))
            guard case .handshake(let handshake) = negotiation.payload else {
                throw AgentProtocolError.incompatible("The agent did not return a handshake.")
            }
            try handshake.validate(required: nil)
            let response = try await client.send(.status)
            guard case .status(let status) = response.payload else {
                throw AgentProtocolError.invalidResponse
            }
            checks.append(
                DoctorCheck(
                    id: "protocol",
                    passed: true,
                    detail:
                        "protocol \(handshake.selectedProtocolVersion ?? 0); agent \(handshake.agentBuild.description); \(handshake.capabilities.count) capabilities"
                ))
            let heartbeatFresh = status.heartbeatAt.map { Date().timeIntervalSince($0) <= 30 } ?? false
            let diagnosticsHealthy = status.diagnosticsHealth?.isHealthy == true
            checks.append(
                DoctorCheck(
                    id: "health",
                    passed: heartbeatFresh && diagnosticsHealthy && status.phase != .degraded,
                    detail:
                        "phase \(status.phase.rawValue); heartbeat \(heartbeatFresh ? "fresh" : "missing/stale"); diagnostics \(diagnosticsHealthy ? "healthy" : "degraded")"
                ))
        } catch {
            checks.append(DoctorCheck(id: "protocol", passed: false, detail: error.localizedDescription))
            checks.append(DoctorCheck(id: "health", passed: false, detail: "unavailable without protocol"))
        }
        let report = DoctorReport(generatedAt: Date(), checks: checks)
        if output.json {
            print(String(decoding: try AgentCodec.encode(report), as: UTF8.self))
        } else {
            print(
                report.checks.map { "[\($0.passed ? "pass" : "fail")] \($0.id): \($0.detail)" }.joined(separator: "\n"))
        }
        if !report.passed { throw ExitCode(CLIExitStatus.doctorFailed.rawValue) }
    }
}

private struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream a bounded number of live status samples."
    )
    @Option(name: .shortAndLong, help: "Number of samples (1...3600).")
    var count = 30
    @Option(name: .shortAndLong, help: "Seconds between samples (1...60).")
    var interval = 2
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard (1...3_600).contains(count) else { throw ValidationError("--count must be 1...3600") }
        guard (1...60).contains(interval) else { throw ValidationError("--interval must be 1...60") }
    }

    func run() async throws {
        let client = CleanroomAgentClient()
        for index in 0..<count {
            do {
                let response = try await client.send(.status)
                guard case .status(let status) = response.payload else {
                    throw AgentProtocolError.invalidResponse
                }
                if output.json {
                    print(String(decoding: try AgentCodec.encode(response), as: UTF8.self))
                } else {
                    print(WatchStatusLine(status: status).description)
                }
                if let failure = CLIExitStatus.failure(for: response.payload) {
                    throw ExitCode(failure.rawValue)
                }
            } catch let error as ExitCode {
                throw error
            } catch {
                let failure = CLIExitStatus.failure(for: error)
                FileHandle.standardError.write(Data("watch failed: \(error.localizedDescription)\n".utf8))
                throw ExitCode(failure.rawValue)
            }
            if index + 1 < count { try await Task.sleep(for: .seconds(interval)) }
        }
    }
}

struct DoctorCheck: Codable, Equatable, Sendable {
    let id: String
    let passed: Bool
    let detail: String
}

struct DoctorReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let checks: [DoctorCheck]
    var passed: Bool { checks.count == 3 && checks.allSatisfy(\.passed) }
}

struct WatchStatusLine: Equatable, Sendable, CustomStringConvertible {
    let sampledAt: Date
    let phase: CleanroomPhase
    let trigger: ProbeState
    let heartbeatAt: Date?
    let message: String

    init(status: CleanroomStatus, sampledAt: Date = Date()) {
        self.sampledAt = sampledAt
        self.phase = status.phase
        self.trigger = status.trigger.state
        self.heartbeatAt = status.heartbeatAt
        self.message = status.lastMessage
    }

    var description: String {
        "\(sampledAt.ISO8601Format()) phase=\(phase.rawValue) trigger=\(trigger.rawValue)"
            + " heartbeat=\(heartbeatAt?.ISO8601Format() ?? "missing") message=\(message)"
    }
}

private struct Incident: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Freeze automatic mutation while preserving recovery state.",
        subcommands: [On.self, Off.self]
    )

    struct On: AsyncParsableCommand {
        func run() async throws { try await CLI.run(.setIncidentMode(true), json: false) }
    }

    struct Off: AsyncParsableCommand {
        func run() async throws { try await CLI.run(.setIncidentMode(false), json: false) }
    }
}

private struct Profiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List or select the single active game profile.",
        subcommands: [List.self, Select.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        func run() async throws { try await CLI.run(.profiles, json: false) }
    }

    struct Select: AsyncParsableCommand {
        @Argument(help: "Profile identifier from `cleanroomctl profiles`.")
        var identifier: String

        func run() async throws { try await CLI.run(.selectProfile(identifier), json: false) }
    }
}

private struct Calibration: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show calibration for the detected Mac hardware."
    )

    func run() async throws { try await CLI.run(.deviceCalibration, json: false) }
}

private struct Receipts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the last three resolved recovery receipts."
    )
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.run(.recoveryReceipts(limit: 3), json: output.json)
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
            try await CLI.run(
                .recover(.discardJournal),
                json: output.json,
                destructiveRecoveryConfirmed: true
            )
        }
    }
}

private enum CLI {
    static func run(
        _ command: AgentCommand,
        json: Bool,
        destructiveRecoveryConfirmed: Bool = false
    ) async throws {
        let client = CleanroomAgentClient()
        do {
            let response = try await client.send(
                command,
                destructiveRecoveryConfirmed: destructiveRecoveryConfirmed
            )
            if json {
                let data = try AgentCodec.encode(response)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(render(response.payload))
            }
            if let status = CLIExitStatus.failure(for: response.payload) {
                throw ExitCode(status.rawValue)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            let status = CLIExitStatus.failure(for: error)
            let prefix = status == .unreachable ? "Agent unreachable" : "Agent protocol failure"
            writeError("\(prefix): \(error.localizedDescription)")
            throw ExitCode(status.rawValue)
        }
    }

    static func render(_ payload: AgentPayload) -> String {
        switch payload {
        case .handshake(let handshake):
            return handshake.incompatibility
                ?? "protocol: \(handshake.selectedProtocolVersion ?? 0); capabilities: \(handshake.capabilities.map(\.rawValue).joined(separator: ","))"
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
            if let health = status.diagnosticsHealth {
                let failures = [health.eventLogError, health.heartbeatError, health.eventReadError]
                    .compactMap { $0 }
                    .joined(separator: "; ")
                lines.append("diagnostics: \(health.isHealthy ? "healthy" : "degraded: \(failures)")")
            }
            return lines.joined(separator: "\n")
        case .transition(let report):
            var lines = ["phase: \(report.phase.rawValue)", "message: \(report.message)"]
            lines += report.results.map {
                "[\($0.outcome.rawValue)] \($0.action) / \($0.target): \($0.detail)"
            }
            return lines.joined(separator: "\n")
        case .preflight(let report):
            let probes = (report.probes ?? []).map {
                let age = $0.age(at: Date()).map { "\(Int($0))s" } ?? "never"
                return "[\($0.state.rawValue)] \($0.name): last success age \(age)"
            }
            return
                (probes
                + report.findings.map {
                    "[\($0.severity.rawValue)] \($0.category) / \($0.summary): \($0.detail)"
                }).joined(separator: "\n")
        case .events(let reports):
            return reports.map {
                "[\($0.phase.rawValue)] \($0.message)"
            }.joined(separator: "\n")
        case .performanceTimeline(let records):
            if records.isEmpty { return "No session performance records." }
            return records.map {
                "[\($0.thermalState)] \($0.operation): \($0.durationMilliseconds) ms"
                    + " · \($0.actions.count) actions · \($0.failureCount) failures"
            }.joined(separator: "\n")
        case .networkLatency(let report):
            guard report.error == nil else { return "latency unavailable: \(report.error!)" }
            return
                "target: \(report.target ?? "unknown")\n"
                + "average: \(report.averageMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unknown")\n"
                + "jitter: \(report.jitterMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unknown")\n"
                + "packet loss: \(report.packetLossPercent.map { String(format: "%.1f%%", $0) } ?? "unknown")\n"
                + "network mutation: none"
        case .systemPressure(let sample):
            return
                "thermal: \(sample.thermal)\n"
                + "battery: \(sample.batteryPercent.map(String.init) ?? "unknown")%\n"
                + "AC power: \(sample.onACPower.map(String.init) ?? "unknown")"
        case .recoveryReceipts(let receipts):
            if receipts.isEmpty { return "No resolved recovery receipts." }
            return receipts.map { receipt in
                let failures = receipt.results.count { $0.outcome.blocksCompletion }
                return
                    "historical recovery receipt: \(receipt.restoredAt.ISO8601Format())"
                    + " · \(receipt.results.count) verified results · \(failures) blocking"
            }.joined(separator: "\n")
        case .profiles(let profiles):
            return profiles.map {
                "\($0.identifier): \($0.name) [\($0.triggerBundleIdentifier)]"
            }.joined(separator: "\n")
        case .profileValidation(let report):
            let header = report.isValid ? "profile valid" : "profile invalid"
            return
                ([header] + report.errors
                + report.mutations.map { mutation in
                    "\(mutation.action): \(mutation.target)"
                }).joined(separator: "\n")
        case .deviceCalibration(let calibration):
            guard let calibration else { return "No calibration saved for this Mac." }
            return
                "hardware: \(calibration.hardwareIdentifier)\n"
                + "pointer linear: \(calibration.pointerLinearEnabled)\n"
                + "display: \(calibration.preferredDisplayRefreshRateHertz) Hz\n"
                + "restore debounce: \(calibration.automaticRestoreDebounceSeconds) s"
        case .profileExport(let data):
            return String(decoding: data, as: UTF8.self)
        case .profileImportPreview(let preview):
            return
                ([preview.canImport ? "import valid" : "import invalid"]
                + preview.validation.errors
                + preview.addedMutations.map { "+ \($0.action): \($0.target)" }
                + preview.removedMutations.map { "- \($0.action): \($0.target)" }).joined(separator: "\n")
        case .requestInProgress:
            return "Request is still in progress; retrying with the same request ID will not duplicate it."
        case .failure(let message):
            return "error: \(message)"
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

enum CLIExitStatus: Int32 {
    case degraded = 2
    case criticalPreflight = 3
    case protocolFailure = 4
    case unreachable = 5
    case requestInProgress = 6
    case doctorFailed = 7

    static func failure(for payload: AgentPayload) -> Self? {
        switch payload {
        case .status(let status) where status.phase == .degraded:
            .degraded
        case .transition(let report) where report.phase == .degraded:
            .degraded
        case .preflight(let report)
        where report.highestSeverity == .critical || !report.isFreshAndComplete():
            .criticalPreflight
        case .requestInProgress:
            .requestInProgress
        case .failure:
            .protocolFailure
        case .recoveryReceipts:
            nil
        case .profiles:
            nil
        case .profileValidation(let report):
            report.isValid ? nil : .protocolFailure
        case .deviceCalibration:
            nil
        case .profileExport:
            nil
        case .profileImportPreview(let preview):
            preview.canImport ? nil : .protocolFailure
        default:
            nil
        }
    }

    static func failure(for error: Error) -> Self {
        guard let protocolError = error as? AgentProtocolError else {
            if error is EncodingError || error is DecodingError { return .protocolFailure }
            return .unreachable
        }
        if case .timedOut = protocolError { return .unreachable }
        return .protocolFailure
    }
}
