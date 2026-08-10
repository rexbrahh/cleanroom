import Foundation

public enum SimulationSystemOperation: String, Codable, Sendable {
    case capture
    case apply
    case verify
    case restore
    case preflight
    case launch
}

public enum SimulationCommand: Codable, Sendable {
    case reconcile
    case enter(force: Bool)
    case restore
    case enforceActive
    case safeLaunch
    case setPaused(Bool)
}

public enum SimulationEvent: Codable, Sendable {
    case trigger(ProbeState)
    case advanceTime(seconds: Double)
    case systemResult(operation: SimulationSystemOperation, outcome: ActionOutcome)
    case timeout(SimulationSystemOperation)
    case corruptJournal
    case restart
    case command(SimulationCommand)
}

public struct SimulationScenario: Codable, Sendable {
    public let events: [SimulationEvent]
    public let automaticRestoreDebounceSeconds: Double

    public init(events: [SimulationEvent], automaticRestoreDebounceSeconds: Double = 5) {
        self.events = events
        self.automaticRestoreDebounceSeconds = max(0, automaticRestoreDebounceSeconds)
    }
}

public struct SimulationActionResult: Codable, Equatable, Sendable {
    public let action: String
    public let target: String
    public let outcome: ActionOutcome
    public let detail: String
}

public struct SimulationStepResult: Codable, Equatable, Sendable {
    public let eventIndex: Int
    public let phase: CleanroomPhase?
    public let message: String
    public let results: [SimulationActionResult]
    public let journalPresent: Bool
}

public actor DeterministicSessionSimulator {
    private let profile: CleanroomProfile
    private let scenario: SimulationScenario
    private let clock: SimulationClock
    private let system: SimulationSystem
    private let journalStore = SimulationJournalStore()
    private let preferencesStore = SimulationPreferencesStore()
    private let receiptStore = SimulationReceiptStore()
    private var engine: CleanroomEngine

    public init(
        scenario: SimulationScenario,
        profile: CleanroomProfile = .phantomForces(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.profile = profile
        self.scenario = scenario
        let clock = SimulationClock(date: startedAt)
        self.clock = clock
        let system = SimulationSystem(profile: profile, clock: clock)
        self.system = system
        self.engine = CleanroomEngine(
            profile: profile,
            system: system,
            journalStore: journalStore,
            receiptStore: receiptStore,
            runtimePreferencesStore: preferencesStore,
            automaticRestoreDebounce: scenario.automaticRestoreDebounceSeconds,
            now: { clock.now() }
        )
    }

    public func run() async -> [SimulationStepResult] {
        var steps: [SimulationStepResult] = []
        for (index, event) in scenario.events.enumerated() {
            let report: TransitionReport?
            var message: String
            switch event {
            case .trigger(let state):
                await system.setTrigger(state)
                report = nil
                message = "trigger=\(state.rawValue)"
            case .advanceTime(let seconds):
                clock.advance(by: seconds)
                report = nil
                message = "time advanced by \(max(0, seconds)) seconds"
            case .systemResult(let operation, let outcome):
                await system.enqueue(operation: operation, outcome: outcome, detail: "simulated \(outcome.rawValue)")
                report = nil
                message = "queued \(operation.rawValue)=\(outcome.rawValue)"
            case .timeout(let operation):
                await system.enqueue(operation: operation, outcome: .unknown, detail: "simulated timeout")
                report = nil
                message = "queued \(operation.rawValue) timeout"
            case .corruptJournal:
                await journalStore.corruptNextRead()
                report = nil
                message = "next journal read is corrupt"
            case .restart:
                engine = makeEngine()
                do {
                    try await engine.loadRuntimePreferences()
                    let status = await engine.status()
                    report = TransitionReport(
                        phase: status.phase,
                        message: "engine restarted: \(status.lastMessage)",
                        results: status.lastResults,
                        preflight: status.preflight
                    )
                } catch {
                    report = TransitionReport(
                        phase: .paused, message: "engine restart failed: \(error.localizedDescription)")
                }
                message = report?.message ?? "engine restarted"
            case .command(let command):
                report = await execute(command)
                message = report?.message ?? "command completed"
            }
            steps.append(
                SimulationStepResult(
                    eventIndex: index,
                    phase: report?.phase,
                    message: message,
                    results: report?.results.map {
                        SimulationActionResult(
                            action: $0.action,
                            target: $0.target,
                            outcome: $0.outcome,
                            detail: $0.detail
                        )
                    } ?? [],
                    journalPresent: await journalStore.journalExists()
                ))
        }
        return steps
    }

    private func execute(_ command: SimulationCommand) async -> TransitionReport {
        switch command {
        case .reconcile: return await engine.reconcile()
        case .enter(let force): return await engine.enter(force: force)
        case .restore: return await engine.restore()
        case .enforceActive: return await engine.enforceActive()
        case .safeLaunch: return await engine.safeLaunch()
        case .setPaused(let paused):
            do {
                try await engine.setPaused(paused)
                let status = await engine.status()
                return TransitionReport(phase: status.phase, message: status.lastMessage)
            } catch {
                return TransitionReport(phase: .degraded, message: error.localizedDescription)
            }
        }
    }

    private func makeEngine() -> CleanroomEngine {
        CleanroomEngine(
            profile: profile,
            system: system,
            journalStore: journalStore,
            receiptStore: receiptStore,
            runtimePreferencesStore: preferencesStore,
            automaticRestoreDebounce: scenario.automaticRestoreDebounceSeconds,
            now: { [clock] in clock.now() }
        )
    }
}

private final class SimulationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) { self.date = date }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by seconds: Double) {
        lock.withLock { date = date.addingTimeInterval(max(0, seconds)) }
    }
}

private actor SimulationSystem: CleanroomSystemControlling {
    private let profile: CleanroomProfile
    private let clock: SimulationClock
    private var trigger: ProbeState = .stopped
    private var queued: [SimulationSystemOperation: [(ActionOutcome, String)]] = [:]

    init(profile: CleanroomProfile, clock: SimulationClock) {
        self.profile = profile
        self.clock = clock
    }

    func setTrigger(_ state: ProbeState) { trigger = state }

    func enqueue(operation: SimulationSystemOperation, outcome: ActionOutcome, detail: String) {
        queued[operation, default: []].append((outcome, detail))
    }

    func probeTrigger() -> TriggerProbe {
        switch trigger {
        case .running:
            TriggerProbe(
                state: .running,
                process: TriggerProcess(
                    processIdentifier: 42,
                    bundleIdentifier: profile.triggerBundleIdentifier,
                    executableURL: nil
                ))
        case .stopped: TriggerProbe(state: .stopped)
        case .unknown: TriggerProbe(state: .unknown, detail: "simulated unknown trigger")
        }
    }

    func captureSnapshot(for profile: CleanroomProfile) throws -> SystemSnapshot {
        let result = next(.capture)
        guard !result.0.blocksCompletion else { throw CleanroomError.mutationFailed(result.1) }
        return SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )
    }

    func apply(profile: CleanroomProfile) -> [ActionResult] { result(.apply, target: profile.name) }
    func verifyApplied(profile: CleanroomProfile) -> [ActionResult] { result(.verify, target: profile.name) }
    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) -> [ActionResult] {
        result(.restore, target: profile.name)
    }

    func preflight(profile: CleanroomProfile) -> PreflightReport {
        let result = next(.preflight)
        let finding =
            result.0.blocksCompletion
            ? PreflightFinding(
                id: "simulated-preflight",
                severity: .critical,
                category: "Simulation",
                summary: result.1,
                detail: result.1
            ) : nil
        let checkedAt = clock.now()
        return PreflightReport(
            generatedAt: checkedAt,
            findings: finding.map { [$0] } ?? [],
            probes: [
                PreflightProbeEvidence(
                    id: "simulation",
                    name: "Simulation",
                    state: result.0.blocksCompletion ? .incomplete : .succeeded,
                    checkedAt: checkedAt,
                    lastSucceededAt: result.0.blocksCompletion ? nil : checkedAt
                )
            ]
        )
    }

    func launchTrigger(bundleIdentifier: String) -> ActionResult {
        result(.launch, target: bundleIdentifier)[0]
    }

    private func result(_ operation: SimulationSystemOperation, target: String) -> [ActionResult] {
        let next = next(operation)
        return [
            ActionResult(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                action: operation.rawValue,
                target: target,
                outcome: next.0,
                detail: next.1,
                occurredAt: clock.now()
            )
        ]
    }

    private func next(_ operation: SimulationSystemOperation) -> (ActionOutcome, String) {
        guard var values = queued[operation], !values.isEmpty else { return (.succeeded, "simulated success") }
        let value = values.removeFirst()
        queued[operation] = values
        return value
    }
}

private actor SimulationJournalStore: RecoveryJournalPersisting {
    private var journal: RecoveryJournal?
    private var corrupt = false

    func corruptNextRead() { corrupt = true }
    func journalExists() -> Bool { journal != nil }
    func loadJournal() throws -> RecoveryJournal? {
        if corrupt {
            corrupt = false
            throw CleanroomError.invalidJournal("simulated corruption")
        }
        return journal
    }
    func saveJournal(_ journal: RecoveryJournal) { self.journal = journal }
    func clearJournal() { journal = nil }
}

private actor SimulationPreferencesStore: RuntimePreferencesPersisting {
    private var preferences = RuntimePreferences()
    func loadPreferences() -> RuntimePreferences { preferences }
    func savePreferences(_ preferences: RuntimePreferences) { self.preferences = preferences }
}

private actor SimulationReceiptStore: RecoveryReceiptPersisting {
    private var receipts: [RecoveryReceipt] = []
    func saveReceipt(_ receipt: RecoveryReceipt) { receipts.insert(receipt, at: 0) }
    func recentReceipts(limit: Int) -> [RecoveryReceipt] { Array(receipts.prefix(max(0, limit))) }
}
