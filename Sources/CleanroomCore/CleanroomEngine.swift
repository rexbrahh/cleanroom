import Foundation

public actor CleanroomEngine {
    private var profile: CleanroomProfile
    private var profiles: [String: CleanroomProfile]
    private let builtInProfileIdentifiers: Set<String>
    private let profileStore: (any ProfilePersisting)?
    private let calibrationStore: (any DeviceCalibrationPersisting)?
    private let hardwareIdentifier: String
    private var deviceCalibration: DeviceCalibration?
    private let system: any CleanroomSystemControlling
    private let journalStore: any RecoveryJournalPersisting
    private let receiptStore: (any RecoveryReceiptPersisting)?
    private let runtimePreferencesStore: (any RuntimePreferencesPersisting)?

    private var phase: CleanroomPhase = .idle
    private var lastMessage = "Cleanroom is idle."
    private var lastResults: [ActionResult] = []
    private var latestPreflight: PreflightReport?
    private var paused = false
    private var incidentMode = false
    private var suppression: AutomaticTransitionSuppression = .none
    private var suppressionSessionIdentifier: UUID?
    private var triggerStoppedSince: Date?
    private var transitionInProgress: TransitionKind?
    private let now: @Sendable () -> Date

    private enum TransitionKind: String {
        case reconcile
        case enter
        case restore
        case enforceActive
        case recover
        case safeLaunch
    }

    /// Duration for which the trigger must remain stopped before an automatic
    /// restore fires. Guards against restore/re-enter thrash when
    /// Roblox relaunches itself (auto-update) or is relaunched right after a
    /// crash. Reconcile frequency cannot shorten it; manual restores are never
    /// debounced.
    private let baseAutomaticRestoreDebounce: TimeInterval
    private var automaticRestoreDebounce: TimeInterval
    /// Safe Launch writes a journal before Roblox exists. Wait this long for
    /// the player to appear before treating that journal as an ended session.
    private let safeLaunchAppearanceTimeout: TimeInterval = 60

    public init(
        profile: CleanroomProfile,
        availableProfiles: [CleanroomProfile] = [],
        profileStore: (any ProfilePersisting)? = nil,
        calibrationStore: (any DeviceCalibrationPersisting)? = nil,
        hardwareIdentifier: String = "unknown",
        system: any CleanroomSystemControlling,
        journalStore: any RecoveryJournalPersisting,
        receiptStore: (any RecoveryReceiptPersisting)? = nil,
        runtimePreferencesStore: (any RuntimePreferencesPersisting)? = nil,
        automaticRestoreDebounce: TimeInterval = 0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profile = profile
        var profiles: [String: CleanroomProfile] = [:]
        for candidate in [profile] + availableProfiles {
            profiles[candidate.identifier] = candidate
        }
        self.profiles = profiles
        self.builtInProfileIdentifiers = Set(profiles.keys)
        self.profileStore = profileStore
        self.calibrationStore = calibrationStore
        self.hardwareIdentifier = hardwareIdentifier
        self.system = system
        self.journalStore = journalStore
        self.receiptStore = receiptStore
        self.runtimePreferencesStore = runtimePreferencesStore
        self.baseAutomaticRestoreDebounce = max(0, automaticRestoreDebounce)
        self.automaticRestoreDebounce = max(0, automaticRestoreDebounce)
        self.now = now
    }

    public func loadRuntimePreferences() async throws {
        guard let runtimePreferencesStore else { return }
        let preferences: RuntimePreferences
        do {
            preferences = try await runtimePreferencesStore.loadPreferences()
        } catch {
            paused = true
            phase = .paused
            lastMessage =
                "Runtime preferences are unreadable; automatic transitions are paused: \(error.localizedDescription)"
            throw error
        }

        paused = preferences.automaticTransitionsPaused
        incidentMode = preferences.incidentMode
        suppression = preferences.automaticTransitionSuppression
        suppressionSessionIdentifier = preferences.suppressionSessionIdentifier
        if let profileStore {
            for customProfile in try await profileStore.loadProfiles() {
                guard !builtInProfileIdentifiers.contains(customProfile.identifier) else {
                    throw CleanroomError.invalidProfile(
                        "custom profile cannot replace built-in \(customProfile.identifier)"
                    )
                }
                profiles[customProfile.identifier] = customProfile
            }
        }
        if let calibrationStore {
            deviceCalibration = try await calibrationStore.calibration(for: hardwareIdentifier)
            automaticRestoreDebounce =
                deviceCalibration?.automaticRestoreDebounceSeconds ?? baseAutomaticRestoreDebounce
        }
        guard let selectedProfile = profiles[preferences.activeProfileIdentifier] else {
            paused = true
            phase = .paused
            throw CleanroomError.invalidRuntimePreferences(
                "unknown active profile \(preferences.activeProfileIdentifier)"
            )
        }
        profile = selectedProfile.applying(deviceCalibration)

        if let expectedSession = suppressionSessionIdentifier {
            let currentSession = try await journalStore.loadJournal()?.sessionIdentifier
            if currentSession != expectedSession {
                suppression = .none
                suppressionSessionIdentifier = nil
                try await persistRuntimePreferences()
            }
        }
        // A completed rollback used to latch .entry while Roblox stayed open.
        // That blocked the next real launch. With no journal there is nothing
        // left to protect; drop stale entry suppression so the next session
        // can enter normally.
        if suppression == .entry, try await journalStore.loadJournal() == nil {
            suppression = .none
            suppressionSessionIdentifier = nil
            try await persistRuntimePreferences()
        }
        phase = paused ? .paused : .idle
    }

    public func setPaused(_ newValue: Bool) async throws {
        if let transitionInProgress {
            throw CleanroomError.transitionInProgress(transitionInProgress.rawValue)
        }
        guard !incidentMode || newValue else {
            throw CleanroomError.mutationFailed("Exit Incident Mode before resuming automatic control.")
        }
        let previous = paused
        paused = newValue
        do {
            try await persistRuntimePreferences()
        } catch {
            paused = previous
            throw error
        }
        phase = newValue ? .paused : .idle
        lastMessage =
            newValue
            ? "Automatic entry and drift repair are paused; saved restoration remains armed."
            : "Automatic transitions resumed."
    }

    public func setIncidentMode(_ enabled: Bool) async throws -> TransitionReport {
        if let transitionInProgress {
            throw CleanroomError.transitionInProgress(transitionInProgress.rawValue)
        }
        let previousPaused = paused
        let previousIncidentMode = incidentMode
        incidentMode = enabled
        paused = enabled || paused
        do {
            try await persistRuntimePreferences()
        } catch {
            paused = previousPaused
            incidentMode = previousIncidentMode
            throw error
        }
        phase = .paused
        lastMessage =
            enabled
            ? "Incident Mode is active; automatic mutations and repair are frozen while recovery state is preserved."
            : "Incident Mode ended; automatic control remains paused until explicitly resumed."
        lastResults = [
            ActionResult(
                action: enabled ? "enter incident mode" : "exit incident mode",
                target: "automatic control",
                outcome: .succeeded,
                detail: enabled
                    ? "Recovery state was preserved and diagnostics were marked for collection."
                    : "No recovery state was discarded."
            )
        ]
        return TransitionReport(phase: phase, message: lastMessage, results: lastResults)
    }

    public func isIncidentModeActive() -> Bool { incidentMode }

    public func profileSummaries() -> [CleanroomProfileSummary] {
        profiles.values
            .map(CleanroomProfileSummary.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func selectProfile(identifier: String) async throws -> CleanroomProfileSummary {
        if let transitionInProgress {
            throw CleanroomError.transitionInProgress(transitionInProgress.rawValue)
        }
        guard let selected = profiles[identifier] else {
            throw CleanroomError.invalidRuntimePreferences("unknown profile \(identifier)")
        }
        guard try await journalStore.loadJournal() == nil else {
            throw CleanroomError.mutationFailed(
                "Restore or discard the active recovery journal before changing profiles."
            )
        }
        let previous = profile
        profile = selected.applying(deviceCalibration)
        do {
            try await persistRuntimePreferences()
        } catch {
            profile = previous
            throw error
        }
        phase = paused ? .paused : .idle
        lastMessage = "Selected profile: \(selected.name)."
        lastResults = []
        return CleanroomProfileSummary(profile: selected)
    }

    public func upsertProfile(_ candidate: CleanroomProfile) async throws -> ProfileValidationReport {
        if let transitionInProgress {
            throw CleanroomError.transitionInProgress(transitionInProgress.rawValue)
        }
        let report = candidate.validationReport()
        guard report.isValid else {
            throw CleanroomError.invalidProfile(report.errors.joined(separator: " "))
        }
        guard !builtInProfileIdentifiers.contains(candidate.identifier) else {
            throw CleanroomError.invalidProfile("built-in profiles cannot be overwritten")
        }
        guard try await journalStore.loadJournal() == nil else {
            throw CleanroomError.mutationFailed(
                "Restore or discard the active recovery journal before editing profiles."
            )
        }
        guard let profileStore else {
            throw CleanroomError.persistenceFailed("custom profile storage is unavailable")
        }
        var customProfiles = try await profileStore.loadProfiles()
        customProfiles.removeAll { $0.identifier == candidate.identifier }
        customProfiles.append(candidate)
        try await profileStore.saveProfiles(customProfiles)
        profiles[candidate.identifier] = candidate
        if profile.identifier == candidate.identifier {
            profile = candidate.applying(deviceCalibration)
        }
        return report
    }

    public func currentDeviceCalibration() -> DeviceCalibration? { deviceCalibration }

    public func deviceCalibrationDraft() -> DeviceCalibration {
        return deviceCalibration
            ?? DeviceCalibration(
                hardwareIdentifier: hardwareIdentifier,
                automaticRestoreDebounceSeconds: baseAutomaticRestoreDebounce
            )
    }

    public func saveDeviceCalibration(_ calibration: DeviceCalibration) async throws {
        try calibration.validate()
        guard calibration.hardwareIdentifier == hardwareIdentifier else {
            throw CleanroomError.invalidCalibration("hardware identity does not match this Mac")
        }
        guard let calibrationStore else {
            throw CleanroomError.persistenceFailed("device calibration storage is unavailable")
        }
        try await calibrationStore.saveCalibration(calibration)
        deviceCalibration = calibration
        automaticRestoreDebounce = calibration.automaticRestoreDebounceSeconds
        guard let baseProfile = profiles[profile.identifier] else { return }
        profile = baseProfile.applying(calibration)
    }

    public func exportProfile(identifier: String) throws -> Data {
        guard let profile = profiles[identifier] else {
            throw CleanroomError.invalidProfile("unknown profile \(identifier)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ProfileTransferDocument(profile: profile))
    }

    public func previewProfileImport(_ data: Data) throws -> ProfileImportPreview {
        let document = try JSONDecoder().decode(ProfileTransferDocument.self, from: data)
        guard document.schemaVersion == ProfileTransferDocument.currentSchemaVersion else {
            throw CleanroomError.invalidProfile(
                "unsupported import schema \(document.schemaVersion)"
            )
        }
        let candidate = document.profile
        var validation = candidate.validationReport()
        if builtInProfileIdentifiers.contains(candidate.identifier) {
            validation = ProfileValidationReport(
                profileIdentifier: candidate.identifier,
                mutations: validation.mutations,
                errors: validation.errors + ["Built-in profile identifiers cannot be imported."]
            )
        }
        let existing = profiles[candidate.identifier]?.validationReport().mutations ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let candidateByID = Dictionary(
            uniqueKeysWithValues: validation.mutations.map { ($0.id, $0) }
        )
        let added = validation.mutations.filter { existingByID[$0.id] != $0 }
        let removed = existing.filter { candidateByID[$0.id] != $0 }
        return ProfileImportPreview(
            profile: candidate,
            validation: validation,
            addedMutations: added,
            removedMutations: removed
        )
    }

    public func status(
        agentStartedAt: Date? = nil,
        heartbeatAt: Date? = nil
    ) async -> CleanroomStatus {
        let trigger = await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier)
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
                heartbeatAt: heartbeatAt,
                incidentMode: incidentMode,
                activeProfile: CleanroomProfileSummary(profile: profile),
                deviceCalibration: deviceCalibration
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
                heartbeatAt: heartbeatAt,
                incidentMode: incidentMode,
                activeProfile: CleanroomProfileSummary(profile: profile),
                deviceCalibration: deviceCalibration
            )
        }
    }

    @discardableResult
    public func reconcile() async -> TransitionReport {
        guard beginTransition(.reconcile) else { return transitionBusyReport() }
        defer { endTransition() }
        return await reconcileUnlocked()
    }

    private func reconcileUnlocked() async -> TransitionReport {
        let trigger = await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier)

        if incidentMode {
            phase = .paused
            lastMessage = "Incident Mode is active; automatic mutations are frozen and recovery state is preserved."
            lastResults = []
            return TransitionReport(phase: .paused, message: lastMessage)
        }

        if paused {
            do {
                if let journal = try await journalStore.loadJournal() {
                    switch trigger.state {
                    case .stopped:
                        if isSafeLaunchPending(journal),
                            now().timeIntervalSince(journal.createdAt) < safeLaunchAppearanceTimeout
                        {
                            triggerStoppedSince = nil
                            phase = .paused
                            lastMessage =
                                "Automatic entry is paused; waiting for Roblox after Safe Launch before restoring."
                            lastResults = []
                            return TransitionReport(phase: .paused, message: lastMessage)
                        }
                        return await automaticRestore()
                    case .unknown:
                        triggerStoppedSince = nil
                        return await degrade(
                            trigger.detail ?? "Roblox process state is unknown during a paused session.")
                    case .running:
                        triggerStoppedSince = nil
                    }
                }
            } catch {
                return await degrade(error.localizedDescription)
            }
            phase = .paused
            lastMessage = "Automatic entry and drift repair are paused; saved restoration remains armed."
            lastResults = []
            return TransitionReport(phase: .paused, message: lastMessage)
        }

        switch trigger.state {
        case .running:
            triggerStoppedSince = nil
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
            let journal: RecoveryJournal?
            do {
                journal = try await journalStore.loadJournal()
            } catch {
                return await degrade(error.localizedDescription)
            }
            if let journal {
                if isSafeLaunchPending(journal) {
                    let waited = now().timeIntervalSince(journal.createdAt)
                    if waited < safeLaunchAppearanceTimeout {
                        triggerStoppedSince = nil
                        phase = .entering
                        lastMessage = "Waiting for Roblox after Safe Launch."
                        return TransitionReport(
                            phase: phase,
                            message: lastMessage,
                            results: lastResults,
                            preflight: latestPreflight
                        )
                    }
                }
                return await automaticRestore()
            }
            triggerStoppedSince = nil
            phase = .idle
            lastMessage = "Roblox is not running."
            lastResults = []
            return TransitionReport(phase: .idle, message: lastMessage)
        case .unknown:
            triggerStoppedSince = nil
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
        let currentTime = now()
        let stoppedSince = triggerStoppedSince ?? currentTime
        triggerStoppedSince = stoppedSince
        let remaining = automaticRestoreDebounce - max(0, currentTime.timeIntervalSince(stoppedSince))
        if remaining > 0 {
            lastMessage =
                "Roblox exited; restoring the saved state once the exit is stable (\(Int(ceil(remaining)))s)…"
            return TransitionReport(
                phase: phase,
                message: lastMessage,
                results: lastResults,
                preflight: latestPreflight
            )
        }
        return await restoreUnlocked()
    }

    @discardableResult
    public func enter(force: Bool = false) async -> TransitionReport {
        guard beginTransition(.enter) else { return transitionBusyReport() }
        defer { endTransition() }
        return await enter(
            trigger: await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier),
            force: force
        )
    }

    @discardableResult
    public func restore() async -> TransitionReport {
        guard beginTransition(.restore) else { return transitionBusyReport() }
        defer { endTransition() }
        return await restoreUnlocked()
    }

    @discardableResult
    public func safeLaunch() async -> TransitionReport {
        guard beginTransition(.safeLaunch) else { return transitionBusyReport() }
        defer { endTransition() }

        guard !paused, !incidentMode else {
            return TransitionReport(
                phase: .paused,
                message: "Resume automatic control before using Safe Launch."
            )
        }
        guard await clearSuppressionForExplicitRecovery() else {
            return await degrade("Retry suppression could not be cleared; Safe Launch was not attempted.")
        }
        let trigger = await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier)
        guard trigger.state == .stopped else {
            let message =
                trigger.state == .running
                ? "Roblox is already running; Safe Launch was not needed."
                : (trigger.detail ?? "Roblox state is unknown; Safe Launch was blocked.")
            return await degrade(message)
        }
        do {
            guard try await journalStore.loadJournal() == nil else {
                return await degrade("Recovery state already exists; restore it before using Safe Launch.")
            }
            let snapshot = try await system.captureSnapshot(for: profile)
            let journal = RecoveryJournal(
                trigger: TriggerProcess(
                    processIdentifier: 0,
                    bundleIdentifier: profile.triggerBundleIdentifier,
                    executableURL: nil
                ),
                snapshot: snapshot,
                safeLaunchPrepared: true,
                profileIdentifier: profile.identifier
            )
            try await journalStore.saveJournal(journal)
            guard try await journalStore.loadJournal()?.sessionIdentifier == journal.sessionIdentifier else {
                return await degrade("Safe Launch recovery state could not be verified after saving.")
            }
        } catch {
            return await degrade(error.localizedDescription)
        }

        let capture = ActionResult(
            action: "capture recovery state",
            target: profile.name,
            outcome: .succeeded,
            detail: "Recovery state was saved and validated before launch."
        )
        let launch = await system.launchTrigger(
            bundleIdentifier: profile.triggerBundleIdentifier
        )
        let results = [capture, launch]
        guard !launch.outcome.blocksCompletion else {
            return await degrade(
                "Roblox did not launch; validated recovery state was retained.",
                results: results
            )
        }
        phase = .entering
        lastMessage = "Roblox launched after recovery state was validated; cleanroom entry is pending detection."
        lastResults = results
        return TransitionReport(phase: phase, message: lastMessage, results: results)
    }

    private func restoreUnlocked() async -> TransitionReport {
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
            return await degrade(error.localizedDescription, suppressing: .restore)
        }
        guard journalBelongsToActiveProfile(journal) else {
            let journalProfileIdentifier = journal.profileIdentifier ?? "roblox-phantom-forces"
            return await degrade(
                "Recovery state belongs to profile \(journalProfileIdentifier) and trigger \(journal.trigger.bundleIdentifier), not \(profile.identifier); no mutation was attempted.",
                suppressing: .restore
            )
        }

        phase = .restoring
        let results = await system.restore(snapshot: journal.snapshot, profile: profile)
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return await degrade(
                "Restoration is incomplete; automatic retries are paused and the recovery journal was retained.",
                results: results,
                suppressing: .restore
            )
        }

        do {
            if let receiptStore {
                try await receiptStore.saveReceipt(
                    RecoveryReceipt(journal: journal, restoredAt: now(), results: results)
                )
            }
            try await journalStore.clearJournal()
        } catch {
            return await degrade(error.localizedDescription, results: results, suppressing: .restore)
        }

        phase = .idle
        await clearSuppressionAfterSuccess()
        triggerStoppedSince = nil
        lastMessage = "Saved desktop and input state restored."
        lastResults = results
        return TransitionReport(phase: phase, message: lastMessage, results: results)
    }

    public func preflight() async -> PreflightReport {
        var findings = await system.preflight(profile: profile).findings
        if let deviceCalibration {
            findings.append(
                PreflightFinding(
                    id: "device-calibration",
                    severity: .information,
                    category: "Calibration",
                    summary: "Device calibration loaded",
                    detail:
                        "Expected display \(deviceCalibration.preferredDisplayRefreshRateHertz) Hz;"
                        + " restore debounce \(deviceCalibration.automaticRestoreDebounceSeconds.formatted()) s."
                )
            )
        }
        let report = PreflightReport(findings: findings)
        latestPreflight = report
        return report
    }

    /// Checks active postconditions and repairs drift only after validating the
    /// recovery journal that authorizes those mutations.
    @discardableResult
    public func enforceActive() async -> TransitionReport {
        guard beginTransition(.enforceActive) else { return transitionBusyReport() }
        defer { endTransition() }
        return await enforceActiveUnlocked()
    }

    private func enforceActiveUnlocked() async -> TransitionReport {
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
            return await degrade(error.localizedDescription)
        }

        let trigger = await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier)
        guard trigger.state == .running else {
            if trigger.state == .stopped {
                return await automaticRestore()
            }
            triggerStoppedSince = nil
            return await degrade(trigger.detail ?? "Roblox process state is unknown.")
        }
        triggerStoppedSince = nil

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
            let triggerAfterRepair = await system.probeTrigger(
                bundleIdentifier: profile.triggerBundleIdentifier
            )
            if triggerAfterRepair.state != .stopped {
                phase = .active
                lastMessage = stayFocusedMessage(results)
                lastResults = results
                return TransitionReport(
                    phase: phase,
                    message: lastMessage,
                    results: results,
                    preflight: latestPreflight
                )
            }
            return await automaticRestore()
        }

        phase = .active
        lastMessage = "Cleanroom drift repaired."
        lastResults = results
        return TransitionReport(phase: phase, message: lastMessage, results: results)
    }

    @discardableResult
    public func recover(_ action: RecoveryAction) async -> TransitionReport {
        guard beginTransition(.recover) else { return transitionBusyReport() }
        defer { endTransition() }
        return await recoverUnlocked(action)
    }

    private func recoverUnlocked(_ action: RecoveryAction) async -> TransitionReport {
        switch action {
        case .retryEntry:
            guard await clearSuppressionForExplicitRecovery() else {
                return await degrade("Retry suppression could not be cleared; entry was not attempted.")
            }
            return await enter(
                trigger: await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier),
                force: true
            )
        case .retryRestore:
            guard await clearSuppressionForExplicitRecovery() else {
                return await degrade("Retry suppression could not be cleared; restoration was not attempted.")
            }
            return await restoreUnlocked()
        case .discardJournal:
            do {
                try await journalStore.clearJournal()
                phase = .idle
                try await updateSuppression(.none, sessionIdentifier: nil)
                lastMessage = "Recovery journal discarded by explicit user action."
                lastResults = []
                return TransitionReport(phase: phase, message: lastMessage)
            } catch {
                return await degrade(error.localizedDescription)
            }
        }
    }

    private func enter(trigger: TriggerProbe, force: Bool) async -> TransitionReport {
        triggerStoppedSince = nil
        guard !incidentMode else {
            return TransitionReport(
                phase: .paused,
                message: "Incident Mode is active; new entry mutations are frozen."
            )
        }
        guard trigger.state != .unknown else {
            return await degrade(trigger.detail ?? "Roblox process state is unknown.")
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
            return await degrade(error.localizedDescription, suppressing: .entry)
        }
        if let existingJournal, !journalBelongsToActiveProfile(existingJournal) {
            return await degrade(
                "Existing recovery state belongs to a different profile; entry was blocked.",
                suppressing: .all
            )
        }

        if existingJournal != nil, phase == .active, !force {
            return TransitionReport(
                phase: .active,
                message: lastMessage.isEmpty ? "Roblox cleanroom remains active." : lastMessage,
                results: lastResults,
                preflight: latestPreflight
            )
        }

        if let existingJournal {
            do {
                try await armSafeLaunchJournalIfNeeded(existingJournal, process: process)
            } catch {
                return await degrade(error.localizedDescription, suppressing: .entry)
            }
        }

        // Only profiles that gate entry on preflight pay its cost up front.
        // For the fixed profile, preflight runs after the session is secured
        // so the ~1.5s of inspection subprocesses never delays entry.
        if profile.blockAutomaticEntryOnCriticalPreflight {
            latestPreflight = await system.preflight(profile: profile)
            if !force,
                latestPreflight?.highestSeverity == .critical
                    || latestPreflight?.isFreshAndComplete(at: now()) != true
            {
                phase = .degraded
                lastMessage = "Competitive preflight is critical, incomplete, or stale."
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
                let journal = RecoveryJournal(
                    trigger: process,
                    snapshot: snapshot,
                    profileIdentifier: profile.identifier
                )
                try await journalStore.saveJournal(journal)
            } catch {
                return await degrade(error.localizedDescription, suppressing: .entry)
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
        await clearSuppressionAfterSuccess()
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
    /// applied.
    ///
    /// If Roblox is still running, stay in the focused session. Restoring the
    /// desktop while the game is up is worse than a leftover helper; drift
    /// repair keeps retrying the stragglers.
    ///
    /// If Roblox is already gone, roll back to the snapshot. A clean rollback
    /// clears the journal. A failed rollback retains it and suppresses both
    /// directions because the on-disk state is uncertain.
    private func rollbackFailedEntry(results: [ActionResult]) async -> TransitionReport {
        let journal: RecoveryJournal?
        do {
            journal = try await journalStore.loadJournal()
        } catch {
            return await degrade(error.localizedDescription, results: results, suppressing: .all)
        }

        let trigger = await system.probeTrigger(bundleIdentifier: profile.triggerBundleIdentifier)
        if trigger.state != .stopped {
            guard journal != nil else {
                return await degrade(
                    "Cleanroom entry failed after recovery state disappeared; automatic transitions are paused.",
                    results: results,
                    suppressing: .all
                )
            }
            phase = .active
            lastMessage = stayFocusedMessage(results)
            lastResults = results
            return TransitionReport(
                phase: phase,
                message: lastMessage,
                results: results,
                preflight: latestPreflight
            )
        }

        guard let journal else {
            return await degrade(
                "Cleanroom entry failed after recovery state disappeared; automatic transitions are paused.",
                results: results,
                suppressing: .all
            )
        }
        let rollbackResults = await system.restore(snapshot: journal.snapshot, profile: profile)
        let combined = results + rollbackResults

        guard !rollbackResults.contains(where: { $0.outcome.blocksCompletion }) else {
            return await degrade(
                "Cleanroom entry failed and automatic rollback was incomplete; the recovery journal was retained.",
                results: combined,
                suppressing: .all
            )
        }

        do {
            try await journalStore.clearJournal()
        } catch {
            return await degrade(error.localizedDescription, results: combined, suppressing: .all)
        }

        phase = .idle
        await clearSuppressionAfterSuccess()
        triggerStoppedSince = nil
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
        suppressing scope: AutomaticTransitionSuppression = .none
    ) async -> TransitionReport {
        phase = .degraded
        var resolvedMessage = message
        if scope != .none {
            let sessionIdentifier = try? await journalStore.loadJournal()?.sessionIdentifier
            do {
                try await updateSuppression(
                    scope,
                    sessionIdentifier: sessionIdentifier,
                    revertOnFailure: false
                )
            } catch {
                resolvedMessage += " Retry suppression could not be saved: \(error.localizedDescription)"
            }
        }
        lastMessage = resolvedMessage
        lastResults = results
        return TransitionReport(
            phase: phase,
            message: resolvedMessage,
            results: results,
            preflight: latestPreflight
        )
    }

    private func clearSuppressionForExplicitRecovery() async -> Bool {
        do {
            try await updateSuppression(.none, sessionIdentifier: nil)
            return true
        } catch {
            return false
        }
    }

    private func clearSuppressionAfterSuccess() async {
        suppression = .none
        suppressionSessionIdentifier = nil
        try? await persistRuntimePreferences()
    }

    private func updateSuppression(
        _ newValue: AutomaticTransitionSuppression,
        sessionIdentifier: UUID?,
        revertOnFailure: Bool = true
    ) async throws {
        let previousSuppression = suppression
        let previousSessionIdentifier = suppressionSessionIdentifier
        suppression = newValue
        suppressionSessionIdentifier = newValue == .none ? nil : sessionIdentifier
        do {
            try await persistRuntimePreferences()
        } catch {
            if revertOnFailure {
                suppression = previousSuppression
                suppressionSessionIdentifier = previousSessionIdentifier
            }
            throw error
        }
    }

    private func persistRuntimePreferences() async throws {
        guard let runtimePreferencesStore else { return }
        try await runtimePreferencesStore.savePreferences(
            RuntimePreferences(
                automaticTransitionsPaused: paused,
                automaticTransitionSuppression: suppression,
                suppressionSessionIdentifier: suppressionSessionIdentifier,
                incidentMode: incidentMode,
                activeProfileIdentifier: profile.identifier
            )
        )
    }

    private func journalBelongsToActiveProfile(_ journal: RecoveryJournal) -> Bool {
        let identifier = journal.profileIdentifier ?? "roblox-phantom-forces"
        return identifier == profile.identifier
            && journal.trigger.bundleIdentifier == profile.triggerBundleIdentifier
    }

    private func isSafeLaunchPending(_ journal: RecoveryJournal) -> Bool {
        journal.safeLaunchPrepared == true && journal.trigger.processIdentifier == 0
    }

    private func armSafeLaunchJournalIfNeeded(
        _ journal: RecoveryJournal,
        process: TriggerProcess
    ) async throws {
        guard isSafeLaunchPending(journal) else { return }
        let armed = RecoveryJournal(
            schemaVersion: journal.schemaVersion,
            sessionIdentifier: journal.sessionIdentifier,
            createdAt: journal.createdAt,
            trigger: process,
            snapshot: journal.snapshot,
            safeLaunchPrepared: false,
            profileIdentifier: journal.profileIdentifier ?? profile.identifier
        )
        try await journalStore.saveJournal(armed)
    }

    private func stayFocusedMessage(_ results: [ActionResult]) -> String {
        let targets = Array(
            Set(results.filter { $0.outcome.blocksCompletion }.map(\.target))
        ).sorted()
        if targets.isEmpty {
            return
                "Competitive mode is active; some postconditions failed, but Roblox is running so desktop state was not restored."
        }
        let listed = targets.prefix(5).joined(separator: ", ")
        return
            "Competitive mode is active; \(listed) did not stay stopped. Desktop state was not restored."
    }

    private func beginTransition(_ transition: TransitionKind) -> Bool {
        guard transitionInProgress == nil else { return false }
        transitionInProgress = transition
        return true
    }

    private func endTransition() {
        transitionInProgress = nil
    }

    private func transitionBusyReport() -> TransitionReport {
        let active = transitionInProgress?.rawValue ?? "unknown"
        return TransitionReport(
            phase: phase,
            message: CleanroomError.transitionInProgress(active).localizedDescription,
            results: lastResults,
            preflight: latestPreflight
        )
    }
}
