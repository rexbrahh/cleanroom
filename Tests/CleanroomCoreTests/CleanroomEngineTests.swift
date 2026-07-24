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

    @Test("failed restore waits for explicit recovery instead of retrying")
    func failedRestoreDoesNotLoop() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, restoreFails: true, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let first = await engine.restore()
        let automatic = await engine.reconcile()

        #expect(first.phase == .degraded)
        #expect(automatic.phase == .degraded)
        #expect(await trace.count(of: "restore") == 1)

        _ = await engine.recover(.retryRestore)
        #expect(await trace.count(of: "restore") == 2)
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

    @Test("preflight does not delay entry for the non-gating profile")
    func preflightRunsAfterApply() async throws {
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
        #expect(events.firstIndex(of: "apply")! < events.firstIndex(of: "preflight")!)
    }

    @Test("failed entry rolls back to the snapshot and clears the journal")
    func failedEntryRollsBackCleanly() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, applyFails: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()

        #expect(report.phase == .idle)
        #expect(!(await store.journalExists()))
        let events = await trace.events
        #expect(events.firstIndex(of: "save-journal")! < events.firstIndex(of: "restore")!)
        #expect(await trace.count(of: "restore") == 1)

        // Automatic re-entry is suppressed until an explicit retry; the monitor
        // loop must not enter/rollback in a hot loop while Roblox stays open.
        let automatic = await engine.reconcile()
        #expect(automatic.phase == .degraded)
        #expect(await trace.count(of: "apply") == 1)

        _ = await engine.recover(.retryEntry)
        #expect(await trace.count(of: "apply") == 2)
    }

    @Test("failed rollback retains the journal and suppresses automatic entry and restore")
    func failedRollbackSuppressesBothDirections() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, restoreFails: true, applyFails: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()
        #expect(report.phase == .degraded)
        #expect(await store.journalExists())
        #expect(await trace.count(of: "restore") == 1)

        await system.setTriggerState(.running)
        let running = await engine.reconcile()
        #expect(running.phase == .degraded)
        #expect(await trace.count(of: "apply") == 1)

        await system.setTriggerState(.stopped)
        let stopped = await engine.reconcile()
        #expect(stopped.phase == .degraded)
        #expect(await trace.count(of: "restore") == 1)

        _ = await engine.recover(.retryRestore)
        #expect(await trace.count(of: "restore") == 2)
    }

    @Test("failed drift repair does not block restoration when Roblox quits")
    func driftFailureDoesNotBlockRestoreOnQuit() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, alwaysFailVerification: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let drift = await engine.enforceActive()
        #expect(drift.phase == .degraded)

        await system.setTriggerState(.stopped)
        let report = await engine.reconcile()

        #expect(report.phase == .idle)
        #expect(!(await store.journalExists()))
        #expect(await trace.count(of: "restore") == 1)
    }

    @Test("automatic restore waits for a stable Roblox exit")
    func automaticRestoreIsDebounced() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 2
        )

        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)

        let third = await engine.reconcile()
        #expect(third.phase == .idle)
        #expect(await trace.count(of: "restore") == 1)
        #expect(!(await store.journalExists()))
    }

    @Test("a Roblox relaunch resets the exit-stability debounce")
    func relaunchResetsDebounce() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 1
        )

        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)

        await system.setTriggerState(.running)
        _ = await engine.reconcile()
        await system.setTriggerState(.stopped)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)

        let settled = await engine.reconcile()
        #expect(settled.phase == .idle)
        #expect(await trace.count(of: "restore") == 1)
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
    private let applyFails: Bool
    private let alwaysFailVerification: Bool
    private var triggerState: ProbeState
    private var verificationFailuresRemaining: Int

    init(
        trace: Trace,
        restoreFails: Bool = false,
        applyFails: Bool = false,
        alwaysFailVerification: Bool = false,
        triggerState: ProbeState = .running,
        verificationFailsOnce: Bool = false
    ) {
        self.trace = trace
        self.restoreFails = restoreFails
        self.applyFails = applyFails
        self.alwaysFailVerification = alwaysFailVerification
        self.triggerState = triggerState
        self.verificationFailuresRemaining = verificationFailsOnce ? 1 : 0
    }

    func setTriggerState(_ state: ProbeState) {
        triggerState = state
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
        if applyFails {
            return [.init(action: "apply", target: profile.name, outcome: .failed, detail: "apply failed")]
        }
        return [.init(action: "apply", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func verifyApplied(profile: CleanroomProfile) async -> [ActionResult] {
        await trace.append("verify")
        if alwaysFailVerification {
            return [.init(action: "verify", target: profile.name, outcome: .failed, detail: "drift")]
        }
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

    func preflight(profile: CleanroomProfile) async -> PreflightReport {
        await trace.append("preflight")
        return PreflightReport(findings: [])
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
