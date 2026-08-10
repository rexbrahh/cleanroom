import CleanroomCore
import CleanroomMac
import CleanroomProtocol
import Foundation
import Testing

@testable import CleanroomAgent

@Suite("Agent security boundary")
struct AgentSecurityBoundaryTests {
    @Test("agent selects a shared protocol and explains unsupported versions")
    func capabilityHandshake() async {
        let runtime = AgentRuntime(
            controller: MacSystemController(
                commands: UnusedCommandRunner(),
                applications: StoppedApplicationManager()
            ),
            preferencesStore: MemoryPreferencesStore(),
            journalStore: MemoryJournalStore()
        )
        let compatible = await runtime.handle(
            AgentRequest(
                command: .handshake(
                    AgentHandshakeRequest(
                        supportedProtocolVersions: [AgentHandshakeResponse.currentProtocolVersion],
                        requiredCapabilities: [.restore]
                    )))
        )
        guard case .handshake(let selected) = compatible.payload else {
            Issue.record("Expected compatible handshake")
            return
        }
        #expect(selected.selectedProtocolVersion == AgentHandshakeResponse.currentProtocolVersion)
        #expect(selected.capabilities.contains(.restore))
        #expect(selected.incompatibility == nil)

        let incompatible = await runtime.handle(
            AgentRequest(
                command: .handshake(
                    AgentHandshakeRequest(supportedProtocolVersions: [999])))
        )
        guard case .handshake(let rejected) = incompatible.payload else {
            Issue.record("Expected incompatible handshake")
            return
        }
        #expect(rejected.selectedProtocolVersion == nil)
        #expect(rejected.incompatibility?.contains("not in") == true)
    }

    @Test("only signed same-user product clients are authorized")
    func clientAuthorization() {
        let appURL = URL(fileURLWithPath: "/Applications/Cleanroom.app/Contents/MacOS/Cleanroom")
        let cliURL = URL(fileURLWithPath: "/Applications/Cleanroom.app/Contents/Resources/cleanroomctl")
        let policy = AgentClientAuthorizationPolicy(
            effectiveUserIdentifier: 501,
            teamIdentifier: "TEAM123",
            adHocExecutableURLs: [appURL, cliURL]
        )
        let legitimate = AgentClientIdentity(
            effectiveUserIdentifier: 501,
            signingIdentifier: "com.rex.cleanroom",
            teamIdentifier: "TEAM123",
            executableURL: appURL,
            signatureIsValid: true
        )

        #expect(policy.permits(legitimate))
        #expect(!policy.permits(replacing(legitimate, effectiveUserIdentifier: 502)))
        #expect(!policy.permits(replacing(legitimate, signingIdentifier: "com.example.attacker")))
        #expect(!policy.permits(replacing(legitimate, teamIdentifier: "OTHERTEAM")))
        #expect(!policy.permits(replacing(legitimate, signatureIsValid: false)))
    }

    @Test("ad hoc clients must be the packaged app or CLI executable")
    func adHocAuthorizationIsPathBound() {
        let appURL = URL(fileURLWithPath: "/Applications/Cleanroom.app/Contents/MacOS/Cleanroom")
        let cliURL = URL(fileURLWithPath: "/Applications/Cleanroom.app/Contents/Resources/cleanroomctl")
        let policy = AgentClientAuthorizationPolicy(
            effectiveUserIdentifier: 501,
            teamIdentifier: nil,
            adHocExecutableURLs: [appURL, cliURL]
        )
        let packagedCLI = AgentClientIdentity(
            effectiveUserIdentifier: 501,
            signingIdentifier: "com.rex.cleanroom.cli",
            teamIdentifier: nil,
            executableURL: cliURL,
            signatureIsValid: true
        )

        #expect(policy.permits(packagedCLI))
        #expect(
            !policy.permits(
                replacing(
                    packagedCLI,
                    executableURL: URL(fileURLWithPath: "/tmp/cleanroomctl")
                )
            )
        )
    }

    @Test("oversized requests are rejected before decoding")
    func requestSizeIsBounded() throws {
        let request = AgentRequest(command: .status)
        let encoded = try AgentCodec.encode(request)
        #expect(try AgentRequestDecoder.decode(encoded) == request)

        let oversized = Data(repeating: 0x20, count: AgentRequestDecoder.maximumEncodedBytes + 1)
        #expect(throws: AgentProtocolError.self) {
            _ = try AgentRequestDecoder.decode(oversized)
        }
    }

    @Test("legacy requests cannot silently confirm destructive recovery")
    func destructiveRecoveryDefaultsToUnconfirmed() throws {
        let identifier = UUID()
        let legacy = """
            {"command":{"recover":{"_0":"discardJournal"}},"identifier":"\(identifier.uuidString)"}
            """

        let request = try AgentCodec.decode(AgentRequest.self, from: Data(legacy.utf8))

        #expect(request.command == .recover(.discardJournal))
        #expect(!request.destructiveRecoveryConfirmed)
    }

    @Test("the agent rejects unconfirmed discard and accepts explicit confirmation")
    func agentEnforcesDestructiveRecoveryConfirmation() async throws {
        let journalStore = MemoryJournalStore()
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-agent-security-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let runtime = AgentRuntime(
            controller: MacSystemController(
                commands: UnusedCommandRunner(),
                applications: StoppedApplicationManager()
            ),
            preferencesStore: MemoryPreferencesStore(),
            journalStore: journalStore,
            diagnostics: DiagnosticsStore(directoryURL: diagnosticsURL)
        )

        let rejected = await runtime.handle(
            AgentRequest(command: .recover(.discardJournal))
        )
        guard case .failure(let message) = rejected.payload else {
            Issue.record("unconfirmed discard did not return a failure")
            return
        }
        #expect(message.contains("requires confirmation"))
        #expect(await journalStore.journalExists())

        let accepted = await runtime.handle(
            AgentRequest(
                command: .recover(.discardJournal),
                destructiveRecoveryConfirmed: true
            )
        )
        guard case .transition(let report) = accepted.payload else {
            Issue.record("confirmed discard did not return a transition")
            return
        }
        #expect(report.phase == .idle)
        #expect(!(await journalStore.journalExists()))
    }

    @Test("duplicate request identities never execute a mutation twice")
    func duplicateRequestsAreIdempotent() async {
        let registry = AgentRequestRegistry(maximumCompletedRequests: 2)
        let gate = AsyncGate()
        let counter = InvocationCounter()
        let request = AgentRequest(command: .restore)
        let first = Task {
            await registry.response(for: request) {
                await counter.increment()
                await gate.wait()
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("completed once")
                )
            }
        }
        await counter.waitUntilInvoked()

        let duplicate = await registry.response(for: request) {
            await counter.increment()
            return AgentResponse(requestIdentifier: request.identifier, payload: .failure("duplicate"))
        }
        #expect(duplicate.payload == .requestInProgress)
        #expect(await counter.value == 1)

        await gate.open()
        let completed = await first.value
        let replayed = await registry.response(for: request) {
            await counter.increment()
            return AgentResponse(requestIdentifier: request.identifier, payload: .failure("duplicate"))
        }
        #expect(replayed == completed)
        #expect(await counter.value == 1)

        let collision = await registry.response(
            for: AgentRequest(identifier: request.identifier, command: .status)
        ) {
            await counter.increment()
            return AgentResponse(requestIdentifier: request.identifier, payload: .requestInProgress)
        }
        guard case .failure(let message) = collision.payload else {
            Issue.record("request ID collision was not rejected")
            return
        }
        #expect(message.contains("different command"))
        #expect(await counter.value == 1)
    }

    @Test("diagnostic append failures are exposed in agent status")
    func diagnosticFailureIsVisible() async throws {
        let blockedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-diagnostics-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedURL)
        defer { try? FileManager.default.removeItem(at: blockedURL) }
        let runtime = AgentRuntime(
            controller: MacSystemController(
                commands: UnusedCommandRunner(),
                applications: StoppedApplicationManager()
            ),
            preferencesStore: MemoryPreferencesStore(),
            journalStore: MemoryJournalStore(),
            diagnostics: DiagnosticsStore(directoryURL: blockedURL)
        )

        _ = await runtime.handle(AgentRequest(command: .setPaused(true)))
        let response = await runtime.handle(AgentRequest(command: .status))
        guard case .status(let status) = response.payload else {
            Issue.record("status response was not returned")
            return
        }

        #expect(status.diagnosticsHealth?.isHealthy == false)
        #expect(status.diagnosticsHealth?.eventLogError != nil)
    }

    @Test("event deduplication includes result target and detail")
    func distinctResultsArePreserved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-diagnostics-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = DiagnosticsStore(directoryURL: directory)
        let runtime = AgentRuntime(
            controller: MacSystemController(
                commands: UnusedCommandRunner(),
                applications: StoppedApplicationManager()
            ),
            preferencesStore: MemoryPreferencesStore(),
            journalStore: MemoryJournalStore(),
            diagnostics: diagnostics
        )
        let first = TransitionReport(
            phase: .active,
            message: "verified",
            results: [
                ActionResult(
                    action: "verify",
                    target: "first",
                    outcome: .succeeded,
                    detail: "detail one"
                )
            ]
        )
        let second = TransitionReport(
            phase: .active,
            message: "verified",
            results: [
                ActionResult(
                    action: "verify",
                    target: "second",
                    outcome: .succeeded,
                    detail: "detail two"
                )
            ]
        )

        await runtime.recordIfChanged(first)
        await runtime.recordIfChanged(second)
        await runtime.recordIfChanged(second)
        let result = try await diagnostics.recentEvents(limit: 10)

        #expect(result.events.count == 2)
        #expect(result.events.flatMap(\.results).map(\.target) == ["first", "second"])
    }

    @Test("agent caps resolved recovery history at three")
    func recoveryHistoryIsBounded() async throws {
        let receiptStore = MemoryReceiptStore()
        let runtime = AgentRuntime(
            controller: MacSystemController(
                commands: UnusedCommandRunner(),
                applications: StoppedApplicationManager()
            ),
            preferencesStore: MemoryPreferencesStore(),
            journalStore: MemoryJournalStore(),
            receiptStore: receiptStore
        )

        let response = await runtime.handle(
            AgentRequest(command: .recoveryReceipts(limit: 500))
        )

        guard case .recoveryReceipts = response.payload else {
            Issue.record("Expected recovery receipts payload")
            return
        }
        #expect(await receiptStore.lastLimit == 3)
    }

    private func replacing(
        _ identity: AgentClientIdentity,
        effectiveUserIdentifier: uid_t? = nil,
        signingIdentifier: String? = nil,
        teamIdentifier: String?? = nil,
        executableURL: URL? = nil,
        signatureIsValid: Bool? = nil
    ) -> AgentClientIdentity {
        AgentClientIdentity(
            effectiveUserIdentifier: effectiveUserIdentifier ?? identity.effectiveUserIdentifier,
            signingIdentifier: signingIdentifier ?? identity.signingIdentifier,
            teamIdentifier: teamIdentifier ?? identity.teamIdentifier,
            executableURL: executableURL ?? identity.executableURL,
            signatureIsValid: signatureIsValid ?? identity.signatureIsValid
        )
    }
}

private actor MemoryJournalStore: RecoveryJournalPersisting {
    private var journal: RecoveryJournal? = RecoveryJournal(
        trigger: TriggerProcess(
            processIdentifier: 42,
            bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
            executableURL: nil
        ),
        snapshot: SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )
    )

    func journalExists() -> Bool { journal != nil }
    func loadJournal() -> RecoveryJournal? { journal }
    func saveJournal(_ journal: RecoveryJournal) { self.journal = journal }
    func clearJournal() { journal = nil }
}

private actor MemoryReceiptStore: RecoveryReceiptPersisting {
    private(set) var lastLimit: Int?

    func saveReceipt(_ receipt: RecoveryReceipt) {}

    func recentReceipts(limit: Int) -> [RecoveryReceipt] {
        lastLimit = limit
        return []
    }
}

private actor MemoryPreferencesStore: RuntimePreferencesPersisting {
    private var preferences = RuntimePreferences()

    func loadPreferences() -> RuntimePreferences { preferences }
    func savePreferences(_ preferences: RuntimePreferences) { self.preferences = preferences }
}

private actor UnusedCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 1)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 1)
    }
}

private actor StoppedApplicationManager: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe { ApplicationProbe(state: .stopped) }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop", target: displayName, outcome: .skipped, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start", target: displayName, outcome: .succeeded, detail: "started")
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() { value += 1 }

    func waitUntilInvoked() async {
        while value == 0 { await Task.yield() }
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
