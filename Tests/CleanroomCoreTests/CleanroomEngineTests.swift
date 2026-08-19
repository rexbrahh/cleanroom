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

    @Test("successful restore saves its receipt before clearing recovery state")
    func successfulRestoreSavesReceiptFirst() async throws {
        let trace = Trace()
        let journal = RecoveryJournal.fixture
        let journalStore = MemoryJournalStore(trace: trace, journal: journal)
        let receiptStore = MemoryReceiptStore(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace),
            journalStore: journalStore,
            receiptStore: receiptStore
        )

        let report = await engine.restore()

        #expect(report.phase == .idle)
        let receipt = try #require(await receiptStore.receipts.first)
        #expect(receipt.sessionIdentifier == journal.sessionIdentifier)
        #expect(receipt.results == report.results)
        let events = await trace.events
        #expect(events.firstIndex(of: "save-receipt")! < events.firstIndex(of: "clear-journal")!)
    }

    @Test("receipt persistence failure retains active recovery state")
    func receiptFailureRetainsJournal() async throws {
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace, journal: .fixture)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace),
            journalStore: journalStore,
            receiptStore: MemoryReceiptStore(trace: trace, saveFails: true)
        )

        let report = await engine.restore()

        #expect(report.phase == .degraded)
        #expect(await journalStore.journalExists())
        #expect(!(await trace.events).contains("clear-journal"))
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

    @Test("Safe Launch validates recovery state before opening Roblox")
    func safeLaunchCapturesBeforeOpening() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let launch = await engine.safeLaunch()

        #expect(launch.phase == .entering)
        let journal = try #require(try await store.loadJournal())
        #expect(journal.safeLaunchPrepared == true)
        #expect(journal.trigger.processIdentifier == 0)
        let events = await trace.events
        #expect(events.firstIndex(of: "capture")! < events.firstIndex(of: "save-journal")!)
        #expect(events.firstIndex(of: "save-journal")! < events.firstIndex(of: "launch-trigger")!)

        await system.setTriggerState(.running)
        let detected = await engine.reconcile()
        #expect(detected.phase == .active)
        #expect(await trace.count(of: "apply") == 1)
        let armed = try #require(try await store.loadJournal())
        #expect(armed.safeLaunchPrepared != true)
        #expect(armed.trigger.processIdentifier == 42)
    }

    @Test("Safe Launch does not restore while waiting for Roblox to appear")
    func safeLaunchDoesNotRestoreBeforeDetection() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 0
        )

        let launch = await engine.safeLaunch()
        #expect(launch.phase == .entering)
        #expect(await store.journalExists())

        let waiting = await engine.reconcile()
        #expect(waiting.phase == .entering)
        #expect(waiting.message.contains("Waiting for Roblox"))
        #expect(await store.journalExists())
        #expect(await trace.count(of: "restore") == 0)
        #expect(await trace.count(of: "apply") == 0)
    }

    @Test("failed Safe Launch retains its validated recovery state")
    func failedSafeLaunchRetainsJournal() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace, triggerState: .stopped, launchFails: true),
            journalStore: store
        )

        let report = await engine.safeLaunch()

        #expect(report.phase == .degraded)
        #expect(await store.journalExists())
        #expect(report.message.contains("retained"))
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

        try await engine.setPaused(true)
        let report = await engine.reconcile()

        #expect(report.phase == .idle)
        #expect(!(await store.journalExists()))
        #expect((await trace.events).contains("restore"))
    }

    @Test("Incident Mode freezes automatic mutation and preserves recovery state")
    func incidentModeFreezesAutomaticMutation() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let preferences = MemoryRuntimePreferencesStore()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace, triggerState: .stopped),
            journalStore: store,
            runtimePreferencesStore: preferences
        )

        let activation = try await engine.setIncidentMode(true)
        let automatic = await engine.reconcile()
        let entry = await engine.enter()

        #expect(activation.results.first?.detail.contains("diagnostics") == true)
        #expect(automatic.phase == .paused)
        #expect(entry.phase == .paused)
        #expect(await store.journalExists())
        #expect(!(await trace.events).contains("restore"))
        #expect(!(await trace.events).contains("apply"))
        #expect((await preferences.current).incidentMode)
    }

    @Test("one selected profile persists and cannot change while recovery is active")
    func profileSelectionHasSingleOwner() async throws {
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace)
        let preferences = MemoryRuntimePreferencesStore()
        let minecraft = CleanroomProfile.minecraft()
        let fakeSystem = FakeSystem(trace: trace)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            availableProfiles: [minecraft],
            system: fakeSystem,
            journalStore: journalStore,
            runtimePreferencesStore: preferences
        )
        try await engine.loadRuntimePreferences()

        _ = try await engine.selectProfile(identifier: minecraft.identifier)
        #expect((await engine.status()).activeProfile?.identifier == minecraft.identifier)
        #expect(await fakeSystem.lastTriggerBundleIdentifier == minecraft.triggerBundleIdentifier)
        #expect((await preferences.current).activeProfileIdentifier == minecraft.identifier)
        let restarted = CleanroomEngine(
            profile: .phantomForces(),
            availableProfiles: [minecraft],
            system: FakeSystem(trace: trace),
            journalStore: journalStore,
            runtimePreferencesStore: preferences
        )
        try await restarted.loadRuntimePreferences()
        #expect((await restarted.status()).activeProfile?.identifier == minecraft.identifier)

        try await journalStore.saveJournal(
            RecoveryJournal(
                trigger: TriggerProcess(
                    processIdentifier: 42,
                    bundleIdentifier: minecraft.triggerBundleIdentifier,
                    executableURL: nil
                ),
                snapshot: .fixture,
                profileIdentifier: minecraft.identifier
            )
        )
        await #expect(throws: CleanroomError.self) {
            try await engine.selectProfile(identifier: "roblox-phantom-forces")
        }
        #expect((await engine.status()).activeProfile?.identifier == minecraft.identifier)
    }

    @Test("custom profile saves are validated and blocked during active recovery")
    func customProfileSaveUsesAgentBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-engine-profile-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace)
        let template = CleanroomProfile.phantomForces()
        let custom = CleanroomProfile(
            identifier: "custom-engine-test",
            name: "Custom engine test",
            triggerBundleIdentifier: "com.example.Game",
            applications: template.applications,
            services: template.services,
            processes: template.processes,
            preferences: template.preferences
        )
        let engine = CleanroomEngine(
            profile: template,
            profileStore: FileProfileStore(directoryURL: directory),
            system: FakeSystem(trace: trace),
            journalStore: journalStore
        )

        #expect(try await engine.upsertProfile(custom).isValid)
        #expect(await engine.profileSummaries().contains { $0.identifier == custom.identifier })

        try await journalStore.saveJournal(.fixture)
        await #expect(throws: CleanroomError.self) {
            try await engine.upsertProfile(custom)
        }
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

    @Test("failed entry while Roblox is running stays focused and does not restore")
    func failedEntryWhileTriggerRunningStaysFocused() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, applyFails: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store
        )

        let report = await engine.enter()

        #expect(report.phase == .active)
        #expect(await store.journalExists())
        #expect(report.message.contains("Desktop state was not restored"))
        #expect(await trace.count(of: "restore") == 0)

        let automatic = await engine.reconcile()
        #expect(automatic.phase == .active)
        #expect(await trace.count(of: "apply") == 1)
        #expect(await trace.count(of: "restore") == 0)
    }

    @Test("failed entry rolls back only after Roblox has already exited")
    func failedEntryRollsBackCleanly() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(trace: trace, applyFails: true, triggerStateAfterApply: .stopped)
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

        let automatic = await engine.reconcile()
        #expect(automatic.phase == .idle)
        #expect(await trace.count(of: "apply") == 1)
        #expect(await trace.count(of: "restore") == 1)
    }

    @Test("failed rollback retains the journal and suppresses automatic entry and restore")
    func failedRollbackSuppressesBothDirections() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace)
        let system = FakeSystem(
            trace: trace,
            restoreFails: true,
            applyFails: true,
            triggerStateAfterApply: .stopped
        )
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
        #expect(drift.phase == .active)
        #expect(await store.journalExists())
        #expect(drift.message.contains("Desktop state was not restored"))

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
        let clock = TestClock()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 2,
            now: { clock.now() }
        )

        for _ in 0..<50 {
            _ = await engine.reconcile()
        }
        #expect(await trace.count(of: "restore") == 0)

        clock.advance(by: 1.99)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)

        clock.advance(by: 0.01)
        let settled = await engine.reconcile()
        #expect(settled.phase == .idle)
        #expect(await trace.count(of: "restore") == 1)
        #expect(!(await store.journalExists()))
    }

    @Test("hardware calibration overrides the restore debounce")
    func calibratedDebounceIsUsed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-engine-calibration-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibrationStore = FileDeviceCalibrationStore(directoryURL: directory)
        try await calibrationStore.saveCalibration(
            DeviceCalibration(
                hardwareIdentifier: "hardware-a",
                automaticRestoreDebounceSeconds: 10
            )
        )
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace, journal: .fixture)
        let clock = TestClock()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            calibrationStore: calibrationStore,
            hardwareIdentifier: "hardware-a",
            system: FakeSystem(trace: trace, triggerState: .stopped),
            journalStore: journalStore,
            runtimePreferencesStore: MemoryRuntimePreferencesStore(),
            automaticRestoreDebounce: 2,
            now: { clock.now() }
        )
        try await engine.loadRuntimePreferences()

        _ = await engine.reconcile()
        clock.advance(by: 6)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)
        clock.advance(by: 4)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 1)
        #expect((await engine.status()).deviceCalibration?.hardwareIdentifier == "hardware-a")
    }

    @Test("a Roblox relaunch resets the exit-stability debounce")
    func relaunchResetsDebounce() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let clock = TestClock()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 1,
            now: { clock.now() }
        )

        _ = await engine.reconcile()
        clock.advance(by: 0.75)
        #expect(await trace.count(of: "restore") == 0)

        await system.setTriggerState(.running)
        _ = await engine.reconcile()
        await system.setTriggerState(.stopped)
        _ = await engine.reconcile()
        clock.advance(by: 0.75)
        #expect(await trace.count(of: "restore") == 0)

        clock.advance(by: 0.25)
        let settled = await engine.reconcile()
        #expect(settled.phase == .idle)
        #expect(await trace.count(of: "restore") == 1)
    }

    @Test("an unknown trigger probe resets the exit-stability interval")
    func unknownProbeResetsDebounce() async throws {
        let trace = Trace()
        let store = MemoryJournalStore(trace: trace, journal: .fixture)
        let system = FakeSystem(trace: trace, triggerState: .stopped)
        let clock = TestClock()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: store,
            automaticRestoreDebounce: 1,
            now: { clock.now() }
        )

        _ = await engine.reconcile()
        clock.advance(by: 0.75)
        await system.setTriggerState(.unknown)
        _ = await engine.reconcile()
        await system.setTriggerState(.stopped)
        _ = await engine.reconcile()
        clock.advance(by: 0.75)

        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 0)

        clock.advance(by: 0.25)
        _ = await engine.reconcile()
        #expect(await trace.count(of: "restore") == 1)
    }

    @Test("failed restore suppression survives an engine restart")
    func restoreSuppressionSurvivesRestart() async throws {
        let trace = Trace()
        let journal = RecoveryJournal.fixture
        let journalStore = MemoryJournalStore(trace: trace, journal: journal)
        let preferencesStore = MemoryRuntimePreferencesStore()
        let system = FakeSystem(trace: trace, restoreFails: true, triggerState: .stopped)
        let first = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )
        try await first.loadRuntimePreferences()

        _ = await first.restore()
        #expect(await trace.count(of: "restore") == 1)
        #expect((await preferencesStore.current).automaticTransitionSuppression == .restore)
        #expect((await preferencesStore.current).suppressionSessionIdentifier == journal.sessionIdentifier)

        let restarted = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )
        try await restarted.loadRuntimePreferences()
        let automatic = await restarted.reconcile()

        #expect(automatic.phase == .degraded)
        #expect(await trace.count(of: "restore") == 1)
    }

    @Test("stale entry suppression is cleared when no recovery journal remains")
    func entrySuppressionSurvivesRestart() async throws {
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace)
        let preferencesStore = MemoryRuntimePreferencesStore(
            RuntimePreferences(automaticTransitionSuppression: .entry)
        )
        let system = FakeSystem(trace: trace)
        let restarted = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )
        try await restarted.loadRuntimePreferences()
        let automatic = await restarted.reconcile()

        #expect(automatic.phase == .active)
        #expect(await trace.count(of: "apply") == 1)
        #expect((await preferencesStore.current).automaticTransitionSuppression == .none)
    }

    @Test("successful explicit recovery clears persisted suppression")
    func explicitRecoveryClearsPersistedSuppression() async throws {
        let trace = Trace()
        let journal = RecoveryJournal.fixture
        let journalStore = MemoryJournalStore(trace: trace, journal: journal)
        let preferencesStore = MemoryRuntimePreferencesStore(
            RuntimePreferences(
                automaticTransitionSuppression: .restore,
                suppressionSessionIdentifier: journal.sessionIdentifier
            )
        )
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace, triggerState: .stopped),
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )
        try await engine.loadRuntimePreferences()

        let report = await engine.recover(.retryRestore)

        #expect(report.phase == .idle)
        #expect(!(await journalStore.journalExists()))
        #expect((await preferencesStore.current).automaticTransitionSuppression == .none)
        #expect((await preferencesStore.current).suppressionSessionIdentifier == nil)
    }

    @Test("suppression for a different recovery session is discarded")
    func staleSessionSuppressionIsDiscarded() async throws {
        let trace = Trace()
        let journal = RecoveryJournal.fixture
        let journalStore = MemoryJournalStore(trace: trace, journal: journal)
        let preferencesStore = MemoryRuntimePreferencesStore(
            RuntimePreferences(
                automaticTransitionSuppression: .restore,
                suppressionSessionIdentifier: UUID()
            )
        )
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: FakeSystem(trace: trace, triggerState: .stopped),
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )

        try await engine.loadRuntimePreferences()
        let report = await engine.reconcile()

        #expect(report.phase == .idle)
        #expect(await trace.count(of: "restore") == 1)
        #expect((await preferencesStore.current).automaticTransitionSuppression == .none)
    }

    @Test("concurrent transition requests cannot interleave mutations")
    func concurrentTransitionsAreRejectedWhileStatusRemainsAvailable() async throws {
        let trace = Trace()
        let journalStore = MemoryJournalStore(trace: trace)
        let system = BlockingSystem()
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: journalStore
        )

        let entering = Task { await engine.enter() }
        await system.waitForApplyStart()

        let reconcile = await engine.reconcile()
        let restore = await engine.restore()
        let recover = await engine.recover(.discardJournal)
        let status = await engine.status()

        #expect(reconcile.message.contains("already in progress: enter"))
        #expect(restore.message.contains("already in progress: enter"))
        #expect(recover.message.contains("already in progress: enter"))
        #expect(status.phase == .entering)
        #expect(await journalStore.journalExists())
        #expect(await system.restoreCalls == 0)
        await #expect(throws: CleanroomError.self) {
            try await engine.setPaused(true)
        }

        await system.releaseApply()
        let completed = await entering.value

        #expect(completed.phase == .active)
        #expect(await system.applyCalls == 1)
    }

    @Test("a journal that disappears after mutation fails closed")
    func missingJournalDuringRollbackFailsClosed() async throws {
        let trace = Trace()
        let journalStore = VanishingJournalStore(trace: trace)
        let preferencesStore = MemoryRuntimePreferencesStore()
        let system = FakeSystem(trace: trace, applyFails: true)
        let engine = CleanroomEngine(
            profile: .phantomForces(),
            system: system,
            journalStore: journalStore,
            runtimePreferencesStore: preferencesStore
        )
        try await engine.loadRuntimePreferences()

        let report = await engine.enter()

        #expect(report.phase == .degraded)
        #expect(report.message.contains("recovery state disappeared"))
        #expect(await trace.count(of: "apply") == 1)
        #expect(await trace.count(of: "restore") == 0)
        #expect((await preferencesStore.current).automaticTransitionSuppression == .all)
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

private actor MemoryRuntimePreferencesStore: RuntimePreferencesPersisting {
    private(set) var current: RuntimePreferences

    init(_ current: RuntimePreferences = RuntimePreferences()) {
        self.current = current
    }

    func loadPreferences() -> RuntimePreferences {
        current
    }

    func savePreferences(_ preferences: RuntimePreferences) {
        current = preferences
    }
}

private actor MemoryReceiptStore: RecoveryReceiptPersisting {
    private let trace: Trace
    private let saveFails: Bool
    private(set) var receipts: [RecoveryReceipt] = []

    init(trace: Trace, saveFails: Bool = false) {
        self.trace = trace
        self.saveFails = saveFails
    }

    func saveReceipt(_ receipt: RecoveryReceipt) async throws {
        await trace.append("save-receipt")
        if saveFails { throw CleanroomError.persistenceFailed("receipt test failure") }
        receipts.append(receipt)
    }

    func recentReceipts(limit: Int) -> [RecoveryReceipt] {
        Array(receipts.prefix(limit))
    }
}

private actor VanishingJournalStore: RecoveryJournalPersisting {
    private let trace: Trace

    init(trace: Trace) {
        self.trace = trace
    }

    func journalExists() -> Bool { false }
    func loadJournal() -> RecoveryJournal? { nil }

    func saveJournal(_ journal: RecoveryJournal) async {
        await trace.append("save-journal")
    }

    func clearJournal() async {
        await trace.append("clear-journal")
    }
}

private actor FakeSystem: CleanroomSystemControlling {
    private let trace: Trace
    private let restoreFails: Bool
    private let applyFails: Bool
    private let alwaysFailVerification: Bool
    private let launchFails: Bool
    private var triggerState: ProbeState
    private let triggerStateAfterApply: ProbeState?
    private var verificationFailuresRemaining: Int
    private(set) var lastTriggerBundleIdentifier: String?

    init(
        trace: Trace,
        restoreFails: Bool = false,
        applyFails: Bool = false,
        alwaysFailVerification: Bool = false,
        triggerState: ProbeState = .running,
        triggerStateAfterApply: ProbeState? = nil,
        verificationFailsOnce: Bool = false,
        launchFails: Bool = false
    ) {
        self.trace = trace
        self.restoreFails = restoreFails
        self.applyFails = applyFails
        self.alwaysFailVerification = alwaysFailVerification
        self.triggerState = triggerState
        self.triggerStateAfterApply = triggerStateAfterApply
        self.verificationFailuresRemaining = verificationFailsOnce ? 1 : 0
        self.launchFails = launchFails
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

    func probeTrigger(bundleIdentifier: String) -> TriggerProbe {
        lastTriggerBundleIdentifier = bundleIdentifier
        return probeTrigger()
    }

    func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot {
        await trace.append("capture")
        return .fixture
    }

    func apply(profile: CleanroomProfile) async -> [ActionResult] {
        await trace.append("apply")
        if let triggerStateAfterApply {
            triggerState = triggerStateAfterApply
        }
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

    func launchTrigger(bundleIdentifier: String) async -> ActionResult {
        await trace.append("launch-trigger")
        return ActionResult(
            action: "launch trigger",
            target: bundleIdentifier,
            outcome: launchFails ? .failed : .succeeded,
            detail: launchFails ? "failed" : "launched"
        )
    }
}

private actor BlockingSystem: CleanroomSystemControlling {
    private let applyGate = AsyncGate()
    private(set) var applyCalls = 0
    private(set) var restoreCalls = 0

    func waitForApplyStart() async {
        while applyCalls == 0 {
            await Task.yield()
        }
    }

    func releaseApply() async {
        await applyGate.open()
    }

    func probeTrigger() -> TriggerProbe {
        TriggerProbe(
            state: .running,
            process: TriggerProcess(
                processIdentifier: 42,
                bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                executableURL: nil
            )
        )
    }

    func captureSnapshot(for profile: CleanroomProfile) -> SystemSnapshot {
        .fixture
    }

    func apply(profile: CleanroomProfile) async -> [ActionResult] {
        applyCalls += 1
        await applyGate.wait()
        return [.init(action: "apply", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func verifyApplied(profile: CleanroomProfile) -> [ActionResult] {
        [.init(action: "verify", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) -> [ActionResult] {
        restoreCalls += 1
        return [.init(action: "restore", target: profile.name, outcome: .succeeded, detail: "ok")]
    }

    func preflight(profile: CleanroomProfile) -> PreflightReport {
        PreflightReport(findings: [])
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
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
