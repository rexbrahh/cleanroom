import Foundation
import Testing

@testable import CleanroomCore

@Suite("Cleanroom recovery state machine")
struct CleanroomEngineTests {
    @Test("journal is persisted before the first mutation")
    func journalPrecedesMutation() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()

        #expect(report.phase == .active)
        let events = await trace.events
        #expect(events.firstIndex(of: "save-journal")! < events.firstIndex(of: "apply")!)
    }

    @Test("invalid existing journal blocks all mutations")
    func invalidJournalBlocksMutation() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(
            trace: trace,
            loadError: CleanroomError.invalidJournal("test corruption")
        )
        let system = FakeSystem(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()

        #expect(report.phase == .degraded)
        #expect(!(await trace.events).contains("apply"))
    }

    @Test("failed restore retains recovery journal")
    func failedRestoreRetainsJournal() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, restoreFails: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.restore()

        #expect(report.phase == .degraded)
        #expect(await store.journalExists())
    }

    @Test("successful restore clears recovery journal")
    func successfulRestoreClearsJournal() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.restore()

        #expect(report.phase == .idle)
        #expect(!(await store.journalExists()))
    }

    @Test("unknown trigger state blocks entry")
    func unknownTriggerBlocksEntry() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, triggerState: .unknown)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()

        #expect(report.phase == .degraded)
        #expect(!(await trace.events).contains("save-journal"))
        #expect(!(await trace.events).contains("apply"))
    }

    @Test("steady-state reconcile does not repeat mutations")
    func steadyStateDoesNotRepeatMutations() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        _ = await engine.enter()
        _ = await engine.reconcile()

        #expect(await trace.count(of: "apply") == 1)
    }

    @Test("drift enforcement verifies before repairing")
    func driftEnforcementVerifiesThenRepairs() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, verificationFailsOnce: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enforceActive()

        #expect(report.phase == .active)
        let events = await trace.events
        #expect(events.firstIndex(of: "verify")! < events.firstIndex(of: "apply")!)
    }

    @Test("paused automatic entry still restores an ended session")
    func pausedSessionStillRestores() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        await engine.setPaused(true)
        let report = await engine.reconcile()

        #expect(report.phase == .idle)
        #expect(!(await store.journalExists()))
        #expect((await trace.events).contains("restore"))
    }
}

private actor Trace {
    var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func count(of event: String) -> Int {
        events.count { $0 == event }
    }
}

private actor MemoryJournalStore: RecoveryJournalPersisting {
    private let trace: Trace
    private var journal: RecoveryJournal?
    private let loadError: CleanroomError?

    init(trace: Trace, journal: RecoveryJournal? = nil, loadError: CleanroomError? = nil) {
        self.trace = trace
        self.journal = journal
        self.loadError = loadError
    }

    func journalExists() -> Bool { journal != nil || loadError != nil }

    func loadJournal() throws -> RecoveryJournal? {
        if let loadError { throw loadError }
        return journal
    }

    func saveJournal(_ journal: RecoveryJournal) async throws {
        await trace.append("save-journal")
        self.journal = journal
    }

    func clearJournal() async throws {
        await trace.append("clear-journal")
        journal = nil
    }
}

private actor FakeSystem: CleanroomSystemControlling {
    private let trace: Trace
    private let restoreFails: Bool
    private let triggerState: ProbeState
    private var verificationFailuresRemaining: Int

    init(
        trace: Trace,
        restoreFails: Bool = false,
        triggerState: ProbeState = .running,
        verificationFailsOnce: Bool = false
    ) {
        self.trace = trace
        self.restoreFails = restoreFails
        self.triggerState = triggerState
        self.verificationFailuresRemaining = verificationFailsOnce ? 1 : 0
    }

    func probeTrigger() -> TriggerProbe {
        switch triggerState {
        case .running:
            TriggerProbe(
                state: .running,
                process: TriggerProcess(
                    processIdentifier: 42,
                    bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                    executableURL: URL(fileURLWithPath: "/Applications/Roblox.app/Contents/MacOS/RobloxPlayer")
                )
            )
        case .stopped:
            TriggerProbe(state: .stopped)
        case .unknown:
            TriggerProbe(state: .unknown, detail: "probe failed")
        }
    }

    func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot {
        await trace.append("capture")
        return .fixture
    }

    func apply(profile: CleanroomProfile) async -> [ActionResult] {
        await trace.append("apply")
        return [.init(action: "apply", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func verifyApplied(profile: CleanroomProfile) async -> [ActionResult] {
        await trace.append("verify")
        if verificationFailuresRemaining > 0 {
            verificationFailuresRemaining -= 1
            return [.init(action: "verify", target: profile.name, outcome: .failed, detail: "drift")]
        }
        return [.init(action: "verify", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) async -> [ActionResult] {
        await trace.append("restore")
        return [
            .init(
                action: "restore",
                target: profile.name,
                outcome: restoreFails ? .failed : .succeeded,
                detail: restoreFails ? "failed" : "ok"
            )
        ]
    }

    func preflight(profile: CleanroomProfile) -> PreflightReport {
        PreflightReport(findings: [])
    }
}

extension RecoveryJournal {
    fileprivate static var fixture: Self {
        RecoveryJournal(
            trigger: TriggerProcess(
                processIdentifier: 42,
                bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                executableURL: nil
            ),
            snapshot: .fixture
        )
    }
}

extension SystemSnapshot {
    fileprivate static var fixture: Self {
        SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )
    }
}
