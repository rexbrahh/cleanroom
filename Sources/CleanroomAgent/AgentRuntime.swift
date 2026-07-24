import CleanroomCore
import CleanroomMac
import CleanroomProtocol
import Foundation
import OSLog

actor AgentRuntime {
    private let controller: MacSystemController
    private let engine: CleanroomEngine
    private let diagnostics: DiagnosticsStore
    private let preferencesStore: any RuntimePreferencesPersisting
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "agent")
    private let startedAt = Date()
    private var heartbeatAt: Date?
    private var monitorTask: Task<Void, Never>?
    private var lastEventSignature = ""
    private var preferencesLoaded = false

    init(
        controller: MacSystemController,
        preferencesStore: any RuntimePreferencesPersisting = FileRuntimePreferencesStore(),
        automaticRestoreDebounce: Int = 5
    ) {
        self.controller = controller
        self.engine = CleanroomEngine(
            profile: .phantomForces(),
            system: controller,
            journalStore: FileRecoveryJournalStore(),
            automaticRestoreDebounce: automaticRestoreDebounce
        )
        self.diagnostics = DiagnosticsStore()
        self.preferencesStore = preferencesStore
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    func handle(_ request: AgentRequest) async -> AgentResponse {
        await loadPreferencesIfNeeded()
        switch request.command {
        case .status:
            let status = await engine.status(
                agentStartedAt: startedAt,
                heartbeatAt: heartbeatAt
            )
            return AgentResponse(requestIdentifier: request.identifier, payload: .status(status))
        case .reconcile:
            return await transitionResponse(request, report: await engine.reconcile())
        case .enter(let force):
            return await transitionResponse(request, report: await engine.enter(force: force))
        case .restore:
            return await transitionResponse(request, report: await engine.restore())
        case .preflight:
            let report = await engine.preflight()
            return AgentResponse(requestIdentifier: request.identifier, payload: .preflight(report))
        case .setPaused(let paused):
            do {
                try await preferencesStore.savePreferences(
                    RuntimePreferences(automaticTransitionsPaused: paused)
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Pause preference was not changed: \(error.localizedDescription)")
                )
            }
            await engine.setPaused(paused)
            let status = await engine.status(agentStartedAt: startedAt, heartbeatAt: heartbeatAt)
            let report = TransitionReport(
                phase: status.phase,
                message: status.lastMessage,
                results: status.lastResults,
                preflight: status.preflight
            )
            try? await diagnostics.append(report)
            return AgentResponse(requestIdentifier: request.identifier, payload: .transition(report))
        case .recover(let action):
            return await transitionResponse(request, report: await engine.recover(action))
        case .recentEvents(let limit):
            let events = await diagnostics.recentEvents(limit: min(max(limit, 0), 200))
            return AgentResponse(requestIdentifier: request.identifier, payload: .events(events))
        case .migrateLegacy:
            return await transitionResponse(request, report: await controller.migrateLegacy())
        }
    }

    private func transitionResponse(
        _ request: AgentRequest,
        report: TransitionReport
    ) async -> AgentResponse {
        try? await diagnostics.append(report)
        logger.info("\(report.phase.rawValue, privacy: .public): \(report.message, privacy: .public)")
        return AgentResponse(requestIdentifier: request.identifier, payload: .transition(report))
    }

    private func monitorLoop() async {
        await loadPreferencesIfNeeded()
        var lastDriftCheck = Date.distantPast
        var lastHeartbeatWrite = Date.distantPast
        while !Task.isCancelled {
            var report = await engine.reconcile()
            if report.phase == .active,
                Date().timeIntervalSince(lastDriftCheck) >= 15
            {
                report = await engine.enforceActive()
                lastDriftCheck = Date()
            }
            await recordIfChanged(report)
            if Date().timeIntervalSince(lastHeartbeatWrite) >= 5 {
                await writeHeartbeat(report)
                lastHeartbeatWrite = Date()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func loadPreferencesIfNeeded() async {
        guard !preferencesLoaded else { return }
        preferencesLoaded = true
        do {
            let preferences = try await preferencesStore.loadPreferences()
            if preferences.automaticTransitionsPaused {
                await engine.setPaused(true)
            }
        } catch {
            await engine.setPaused(true)
            logger.error(
                "Runtime preferences are unreadable; automatic transitions were paused: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recordIfChanged(_ report: TransitionReport) async {
        let signature =
            "\(report.phase.rawValue)\u{0}\(report.message)\u{0}\(report.results.map(\.outcome.rawValue).joined(separator: ","))"
        guard signature != lastEventSignature else { return }
        lastEventSignature = signature
        do {
            try await diagnostics.append(report)
        } catch {
            logger.error("Event log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeHeartbeat(_ report: TransitionReport) async {
        let now = Date()
        heartbeatAt = now
        do {
            try await diagnostics.writeHeartbeat(
                AgentHeartbeat(
                    processIdentifier: getpid(),
                    startedAt: startedAt,
                    updatedAt: now,
                    phase: report.phase,
                    message: report.message
                ))
        } catch {
            logger.error("Heartbeat write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
