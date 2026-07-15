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
    private var automaticRetrySuppressed = false

    public init(
        profile: CleanroomProfile,
        system: any CleanroomSystemControlling,
        journalStore: any RecoveryJournalPersisting
    ) {
        self.profile = profile
        self.system = system
        self.journalStore = journalStore
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
            if paused {
                phase = .paused
            } else if journal != nil, phase == .idle {
                phase = .active
            }
            return CleanroomStatus(
                phase: phase,
                trigger: trigger,
                journal: journal,
                lastMessage: lastMessage,
                lastResults: lastResults,
                preflight: latestPreflight,
                agentStartedAt: agentStartedAt,
                heartbeatAt: heartbeatAt
            )
        } catch {
            phase = .degraded
            lastMessage = error.localizedDescription
            return CleanroomStatus(
                phase: .degraded,
                trigger: trigger,
                journal: nil,
                lastMessage: lastMessage,
                lastResults: lastResults,
                preflight: latestPreflight,
                agentStartedAt: agentStartedAt,
                heartbeatAt: heartbeatAt
            )
        }
    }

    @discardableResult
    public func reconcile() async -> TransitionReport {
        if automaticRetrySuppressed {
            phase = .degraded
            return TransitionReport(
                phase: .degraded,
                message: lastMessage,
                results: lastResults,
                preflight: latestPreflight
            )
        }

        if paused {
            let trigger = await system.probeTrigger()
            if await journalStore.journalExists() {
                switch trigger.state {
                case .stopped:
                    return await restore()
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

        let trigger = await system.probeTrigger()
        switch trigger.state {
        case .running:
            return await enter(trigger: trigger, force: false)
        case .stopped:
            if await journalStore.journalExists() {
                return await restore()
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
            return degrade(error.localizedDescription, suppressAutomaticRetry: true)
        }

        phase = .restoring
        let results = await system.restore(snapshot: journal.snapshot, profile: profile)
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return degrade(
                "Restoration is incomplete; automatic retries are paused and the recovery journal was retained.",
                results: results,
                suppressAutomaticRetry: true
            )
        }

        do {
            try await journalStore.clearJournal()
        } catch {
            return degrade(error.localizedDescription, results: results)
        }

        phase = .idle
        automaticRetrySuppressed = false
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
                return await restore()
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
                suppressAutomaticRetry: true
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
            automaticRetrySuppressed = false
            return await enter(force: true)
        case .retryRestore:
            automaticRetrySuppressed = false
            return await restore()
        case .discardJournal:
            do {
                try await journalStore.clearJournal()
                phase = .idle
                automaticRetrySuppressed = false
                lastMessage = "Recovery journal discarded by explicit user action."
                lastResults = []
                return TransitionReport(phase: phase, message: lastMessage)
            } catch {
                return degrade(error.localizedDescription)
            }
        }
    }

    private func enter(trigger: TriggerProbe, force: Bool) async -> TransitionReport {
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
            return degrade(error.localizedDescription, suppressAutomaticRetry: true)
        }

        if existingJournal != nil, phase == .active, !force {
            return TransitionReport(
                phase: .active,
                message: "Roblox cleanroom remains active.",
                results: lastResults,
                preflight: latestPreflight
            )
        }

        latestPreflight = await system.preflight(profile: profile)
        if !force,
            profile.blockAutomaticEntryOnCriticalPreflight,
            latestPreflight?.highestSeverity == .critical
        {
            phase = .degraded
            lastMessage = "Competitive preflight contains a critical blocker."
            lastResults = []
            return TransitionReport(
                phase: phase,
                message: lastMessage,
                preflight: latestPreflight
            )
        }

        if existingJournal == nil {
            phase = .entering
            do {
                let snapshot = try await system.captureSnapshot(for: profile)
                let journal = RecoveryJournal(trigger: process, snapshot: snapshot)
                try await journalStore.saveJournal(journal)
            } catch {
                return degrade(error.localizedDescription, suppressAutomaticRetry: true)
            }
        }

        phase = .entering
        var results = await system.apply(profile: profile)
        results.append(contentsOf: await system.verifyApplied(profile: profile))
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return degrade(
                "Cleanroom entry verification failed; automatic retries are paused and recovery state was retained.",
                results: results,
                suppressAutomaticRetry: true
            )
        }

        phase = .active
        automaticRetrySuppressed = false
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

    private func degrade(
        _ message: String,
        results: [ActionResult] = [],
        suppressAutomaticRetry: Bool = false
    ) -> TransitionReport {
        phase = .degraded
        if suppressAutomaticRetry {
            automaticRetrySuppressed = true
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
