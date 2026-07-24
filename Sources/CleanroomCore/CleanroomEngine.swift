import Foundation

public actor CleanroomEngine {
    private let profile: CleanroomProfile
    private let system: any CleanroomSystemControlling
    private let journalStore: any RecoveryJournalPersisting

    private var phase: CleanroomPhase = .idle
    private var lastMessage = "Cleanroom is idle."
    private var lastResults: [ActionResult] = []
    private var latestPreflight: PreflightReport?
    private var paused = false
    private var suppression: Suppression = .none
    private var stoppedProbesSeen = 0

    /// Number of consecutive stopped trigger probes required before an
    /// automatic restore fires. Guards against restore/re-enter thrash when
    /// Roblox relaunches itself (auto-update) or is relaunched right after a
    /// crash. Manual restores are never debounced.
    private let automaticRestoreDebounce: Int

    /// Scopes automatic-retry suppression to the transition kind that failed.
    /// A failed entry never blocks restoration of a saved session; a failed
    /// restore never triggers a re-entry attempt. `.all` is reserved for the
    /// case where a rollback itself failed and the on-disk state is uncertain.
    private enum Suppression: Sendable {
        case none
        case entry
        case restore
        case all

        var blocksEntry: Bool { self == .entry || self == .all }
        var blocksRestore: Bool { self == .restore || self == .all }
    }

    public init(
        profile: CleanroomProfile,
        system: any CleanroomSystemControlling,
        journalStore: any RecoveryJournalPersisting,
        automaticRestoreDebounce: Int = 0
    ) {
        self.profile = profile
        self.system = system
        self.journalStore = journalStore
        self.automaticRestoreDebounce = max(0, automaticRestoreDebounce)
    }

    public func setPaused(_ newValue: Bool) {
        paused = newValue
        phase = newValue ? .paused : .idle
        lastMessage =
            newValue
            ? "Automatic entry and drift repair are paused; saved restoration remains armed."
            : "Automatic transitions resumed."
    }

    public func status(
        agentStartedAt: Date? = nil,
        heartbeatAt: Date? = nil
    ) async -> CleanroomStatus {
        let trigger = await system.probeTrigger()
        do {
            let journal = try await journalStore.loadJournal()
            let reportedPhase: CleanroomPhase
            if paused {
                reportedPhase = .paused
            } else if journal != nil, phase == .idle {
                reportedPhase = .active
            } else {
                reportedPhase = phase
            }
            return CleanroomStatus(
                phase: reportedPhase,
                trigger: trigger,
                journal: journal,
                lastMessage: lastMessage,
                lastResults: lastResults,
                preflight: latestPreflight,
                agentStartedAt: agentStartedAt,
                heartbeatAt: heartbeatAt
            )
        } catch {
            return CleanroomStatus(
                phase: .degraded,
                trigger: trigger,
                journal: nil,
                lastMessage: error.localizedDescription,
                lastResults: lastResults,
                preflight: latestPreflight,
                agentStartedAt: agentStartedAt,
                heartbeatAt: heartbeatAt
            )
        }
    }

    @discardableResult
    public func reconcile() async -> TransitionReport {
        let trigger = await system.probeTrigger()

        if paused {
            if await journalStore.journalExists() {
                switch trigger.state {
                case .stopped:
                    return await automaticRestore()
                case .unknown:
                    return degrade(trigger.detail ?? "Roblox process state is unknown during a paused session.")
                case .running:
                    break
                }
            }
            phase = .paused
            lastMessage = "Automatic entry and drift repair are paused; saved restoration remains armed."
            lastResults = []
            return TransitionReport(phase: .paused, message: lastMessage)
        }

        switch trigger.state {
        case .running:
            stoppedProbesSeen = 0
            guard !suppression.blocksEntry else {
                phase = .degraded
                return TransitionReport(
                    phase: .degraded,
                    message: lastMessage,
                    results: lastResults,
                    preflight: latestPreflight
                )
            }
            return await enter(trigger: trigger, force: false)
        case .stopped:
            if await journalStore.journalExists() {
                return await automaticRestore()
            }
            phase = .idle
            lastMessage = "Roblox is not running."
            lastResults = []
            return TransitionReport(phase: .idle, message: lastMessage)
        case .unknown:
            phase = .degraded
            lastMessage = trigger.detail ?? "Roblox process state is unknown."
            lastResults = []
            return TransitionReport(phase: .degraded, message: lastMessage)
        }
    }

    /// Automatic restoration is suppressed only when a restore already failed
    /// (or a rollback left the on-disk state uncertain). A failed entry never
    /// blocks restore-on-quit: returning the saved state is always the safe
    /// direction.
    private func automaticRestore() async -> TransitionReport {
        guard !suppression.blocksRestore else {
            phase = .degraded
            return TransitionReport(
                phase: .degraded,
                message: lastMessage,
                results: lastResults,
                preflight: latestPreflight
            )
        }
        stoppedProbesSeen += 1
        if stoppedProbesSeen <= automaticRestoreDebounce {
            let remaining = automaticRestoreDebounce - stoppedProbesSeen + 1
            lastMessage =
                "Roblox exited; restoring the saved state once the exit is stable (\(remaining)s)…"
            return TransitionReport(
                phase: phase,
                message: lastMessage,
                results: lastResults,
                preflight: latestPreflight
            )
        }
        return await restore()
    }

    @discardableResult
    public func enter(force: Bool = false) async -> TransitionReport {
        await enter(trigger: await system.probeTrigger(), force: force)
    }

    @discardableResult
    public func restore() async -> TransitionReport {
        let journal: RecoveryJournal
        do {
            guard let loaded = try await journalStore.loadJournal() else {
                phase = .idle
                lastMessage = "No recovery journal exists."
                lastResults = []
                return TransitionReport(phase: .idle, message: lastMessage)
            }
            journal = loaded
        } catch {
            return degrade(error.localizedDescription, suppressing: .restore)
        }

        phase = .restoring
        let results = await system.restore(snapshot: journal.snapshot, profile: profile)
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return degrade(
                "Restoration is incomplete; automatic retries are paused and the recovery journal was retained.",
                results: results,
                suppressing: .restore
            )
        }

        do {
            try await journalStore.clearJournal()
        } catch {
            return degrade(error.localizedDescription, results: results, suppressing: .restore)
        }

        phase = .idle
        suppression = .none
        stoppedProbesSeen = 0
        lastMessage = "Saved desktop and input state restored."
        lastResults = results
        return TransitionReport(phase: phase, message: lastMessage, results: results)
    }

    public func preflight() async -> PreflightReport {
        let report = await system.preflight(profile: profile)
        latestPreflight = report
        return report
    }

    /// Checks active postconditions and repairs drift only after validating the
    /// recovery journal that authorizes those mutations.
    @discardableResult
    public func enforceActive() async -> TransitionReport {
        guard !paused else {
            return TransitionReport(phase: .paused, message: "Automatic transitions are paused.")
        }

        do {
            guard try await journalStore.loadJournal() != nil else {
                phase = .idle
                lastMessage = "No active cleanroom session exists."
                lastResults = []
                return TransitionReport(phase: phase, message: lastMessage)
            }
        } catch {
            return degrade(error.localizedDescription)
        }

        let trigger = await system.probeTrigger()
        guard trigger.state == .running else {
            if trigger.state == .stopped {
                return await automaticRestore()
            }
            return degrade(trigger.detail ?? "Roblox process state is unknown.")
        }

        let verification = await system.verifyApplied(profile: profile)
        guard verification.contains(where: { $0.outcome.blocksCompletion }) else {
            phase = .active
            lastMessage = "Cleanroom postconditions verified."
            lastResults = verification
            return TransitionReport(phase: phase, message: lastMessage, results: verification)
        }

        phase = .entering
        var results = await system.apply(profile: profile)
        results.append(contentsOf: await system.verifyApplied(profile: profile))
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return degrade(
                "Cleanroom drift repair failed; automatic retries are paused and recovery state was retained.",
                results: results,
                suppressing: .entry
            )
        }

        phase = .active
        lastMessage = "Cleanroom drift repaired."
        lastResults = results
        return TransitionReport(phase: phase, message: lastMessage, results: results)
    }

    @discardableResult
    public func recover(_ action: RecoveryAction) async -> TransitionReport {
        switch action {
        case .retryEntry:
            suppression = .none
            return await enter(force: true)
        case .retryRestore:
            suppression = .none
            return await restore()
        case .discardJournal:
            do {
                try await journalStore.clearJournal()
                phase = .idle
                suppression = .none
                lastMessage = "Recovery journal discarded by explicit user action."
                lastResults = []
                return TransitionReport(phase: phase, message: lastMessage)
            } catch {
                return degrade(error.localizedDescription)
            }
        }
    }

    private func enter(trigger: TriggerProbe, force: Bool) async -> TransitionReport {
        stoppedProbesSeen = 0
        guard trigger.state != .unknown else {
            return degrade(trigger.detail ?? "Roblox process state is unknown.")
        }
        guard trigger.state == .running, let process = trigger.process else {
            phase = .idle
            lastMessage = CleanroomError.missingTrigger.localizedDescription
            lastResults = []
            return TransitionReport(phase: .idle, message: lastMessage)
        }

        let existingJournal: RecoveryJournal?
        do {
            existingJournal = try await journalStore.loadJournal()
        } catch {
            return degrade(error.localizedDescription, suppressing: .entry)
        }

        if existingJournal != nil, phase == .active, !force {
            return TransitionReport(
                phase: .active,
                message: "Roblox cleanroom remains active.",
                results: lastResults,
                preflight: latestPreflight
            )
        }

        // Only profiles that gate entry on preflight pay its cost up front.
        // For the fixed profile, preflight runs after the session is secured
        // so the ~1.5s of inspection subprocesses never delays entry.
        if profile.blockAutomaticEntryOnCriticalPreflight {
            latestPreflight = await system.preflight(profile: profile)
            if !force, latestPreflight?.highestSeverity == .critical {
                phase = .degraded
                lastMessage = "Competitive preflight contains a critical blocker."
                lastResults = []
                return TransitionReport(
                    phase: phase,
                    message: lastMessage,
                    preflight: latestPreflight
                )
            }
        }

        if existingJournal == nil {
            phase = .entering
            do {
                let snapshot = try await system.captureSnapshot(for: profile)
                let journal = RecoveryJournal(trigger: process, snapshot: snapshot)
                try await journalStore.saveJournal(journal)
            } catch {
                return degrade(error.localizedDescription, suppressing: .entry)
            }
        }

        phase = .entering
        var results = await system.apply(profile: profile)
        results.append(contentsOf: await system.verifyApplied(profile: profile))
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return await rollbackFailedEntry(results: results)
        }

        if !profile.blockAutomaticEntryOnCriticalPreflight {
            latestPreflight = await system.preflight(profile: profile)
        }

        phase = .active
        suppression = .none
        lastMessage =
            existingJournal == nil
            ? "Roblox cleanroom entered."
            : "Roblox cleanroom re-enforced."
        lastResults = results
        return TransitionReport(
            phase: phase,
            message: lastMessage,
            results: results,
            preflight: latestPreflight
        )
    }

    /// Entry failed after the journal was saved and some mutations were
    /// applied. Roll back to the snapshot so the user is never stranded with
    /// helpers stopped while Roblox is unplayable.
    ///
    /// - Clean rollback: journal cleared, phase `idle`, and automatic entry is
    ///   suppressed until an explicit retry (otherwise the monitor loop would
    ///   re-enter and fail again every second).
    /// - Failed rollback: journal retained and both directions are suppressed;
    ///   the on-disk state is uncertain, so only explicit recovery actions may
    ///   proceed.
    private func rollbackFailedEntry(results: [ActionResult]) async -> TransitionReport {
        let journal: RecoveryJournal?
        do {
            journal = try await journalStore.loadJournal()
        } catch {
            return degrade(error.localizedDescription, results: results, suppressing: .all)
        }

        var rollbackResults: [ActionResult] = []
        if let journal {
            rollbackResults = await system.restore(snapshot: journal.snapshot, profile: profile)
        }
        let combined = results + rollbackResults

        guard !rollbackResults.contains(where: { $0.outcome.blocksCompletion }) else {
            return degrade(
                "Cleanroom entry failed and automatic rollback was incomplete; the recovery journal was retained.",
                results: combined,
                suppressing: .all
            )
        }

        do {
            try await journalStore.clearJournal()
        } catch {
            return degrade(error.localizedDescription, results: combined, suppressing: .all)
        }

        phase = .idle
        suppression = .entry
        lastMessage = "Cleanroom entry failed; the pre-entry state was restored automatically."
        lastResults = combined
        return TransitionReport(
            phase: phase,
            message: lastMessage,
            results: combined,
            preflight: latestPreflight
        )
    }

    private func degrade(
        _ message: String,
        results: [ActionResult] = [],
        suppressing scope: Suppression = .none
    ) -> TransitionReport {
        phase = .degraded
        if scope != .none {
            suppression = scope
        }
        lastMessage = message
        lastResults = results
        return TransitionReport(
            phase: phase,
            message: message,
            results: results,
            preflight: latestPreflight
        )
    }
}
