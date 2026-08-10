import CleanroomCore
import CleanroomMac
import CleanroomProtocol
import Foundation
import OSLog

actor AgentRuntime {
    private let controller: MacSystemController
    private let engine: CleanroomEngine
    private let diagnostics: DiagnosticsStore
    private let receiptStore: any RecoveryReceiptPersisting
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "agent")
    private let startedAt = Date()
    private var heartbeatAt: Date?
    private var diagnosticsHealth = DiagnosticsHealth()
    private var monitorTask: Task<Void, Never>?
    private var lastEventSignature = ""
    private var preferencesLoadTask: Task<Void, Never>?

    init(
        controller: MacSystemController,
        preferencesStore: any RuntimePreferencesPersisting = FileRuntimePreferencesStore(),
        journalStore: any RecoveryJournalPersisting = FileRecoveryJournalStore(),
        receiptStore: any RecoveryReceiptPersisting = FileRecoveryReceiptStore(),
        profileStore: any ProfilePersisting = FileProfileStore(),
        calibrationStore: any DeviceCalibrationPersisting = FileDeviceCalibrationStore(),
        hardwareIdentifier: String = MacHardwareIdentity.current,
        diagnostics: DiagnosticsStore = DiagnosticsStore(),
        automaticRestoreDebounce: TimeInterval = 5
    ) {
        self.controller = controller
        self.receiptStore = receiptStore
        self.engine = CleanroomEngine(
            profile: .phantomForces(),
            availableProfiles: CleanroomProfile.builtIn(),
            profileStore: profileStore,
            calibrationStore: calibrationStore,
            hardwareIdentifier: hardwareIdentifier,
            system: controller,
            journalStore: journalStore,
            receiptStore: receiptStore,
            runtimePreferencesStore: preferencesStore,
            automaticRestoreDebounce: automaticRestoreDebounce
        )
        self.diagnostics = diagnostics
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
        case .handshake(let handshake):
            let capabilities = AgentCapability.allCases
            let selected =
                handshake.supportedProtocolVersions.contains(
                    AgentHandshakeResponse.currentProtocolVersion)
                ? AgentHandshakeResponse.currentProtocolVersion : nil
            let missing = handshake.requiredCapabilities.filter { !capabilities.contains($0) }
            let incompatibility: String?
            if selected == nil {
                incompatibility =
                    "Agent protocol \(AgentHandshakeResponse.currentProtocolVersion) is not in the client's supported set \(handshake.supportedProtocolVersions)."
            } else if !missing.isEmpty {
                incompatibility = "Missing capabilities: \(missing.map(\.rawValue).joined(separator: ", "))."
            } else {
                incompatibility = nil
            }
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .handshake(
                    AgentHandshakeResponse(
                        selectedProtocolVersion: selected,
                        capabilities: capabilities,
                        incompatibility: incompatibility
                    )))
        case .status:
            let status = await engine.status(
                agentStartedAt: startedAt,
                heartbeatAt: heartbeatAt
            )
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .status(statusWithDiagnostics(status))
            )
        case .reconcile:
            let startedAt = Date()
            return await transitionResponse(
                request, report: await engine.reconcile(), operation: "reconcile", startedAt: startedAt)
        case .enter(let force):
            let startedAt = Date()
            return await transitionResponse(
                request, report: await engine.enter(force: force), operation: "enter", startedAt: startedAt)
        case .restore:
            let startedAt = Date()
            return await transitionResponse(
                request, report: await engine.restore(), operation: "restore", startedAt: startedAt)
        case .safeLaunch:
            let startedAt = Date()
            return await transitionResponse(
                request, report: await engine.safeLaunch(), operation: "safe-launch", startedAt: startedAt)
        case .preflight:
            let report = await engine.preflight()
            return AgentResponse(requestIdentifier: request.identifier, payload: .preflight(report))
        case .setPaused(let paused):
            do {
                try await engine.setPaused(paused)
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Pause preference was not changed: \(error.localizedDescription)")
                )
            }
            let status = await engine.status(agentStartedAt: startedAt, heartbeatAt: heartbeatAt)
            let report = TransitionReport(
                phase: status.phase,
                message: status.lastMessage,
                results: status.lastResults,
                preflight: status.preflight
            )
            _ = await appendDiagnostic(report)
            return AgentResponse(requestIdentifier: request.identifier, payload: .transition(report))
        case .setIncidentMode(let enabled):
            do {
                let report = try await engine.setIncidentMode(enabled)
                return await transitionResponse(request, report: report)
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Incident Mode was not changed: \(error.localizedDescription)")
                )
            }
        case .recover(let action):
            if action == .discardJournal, !request.destructiveRecoveryConfirmed {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure(
                        "Discarding recovery state requires confirmation in the authenticated request."
                    )
                )
            }
            let startedAt = Date()
            return await transitionResponse(
                request, report: await engine.recover(action), operation: "recover-\(action.rawValue)",
                startedAt: startedAt)
        case .recentEvents(let limit):
            do {
                let result = try await diagnostics.recentEvents(limit: min(max(limit, 0), 200))
                setEventReadError(
                    result.malformedLineCount == 0
                        ? nil : "Ignored \(result.malformedLineCount) malformed diagnostic event line(s)."
                )
                return AgentResponse(requestIdentifier: request.identifier, payload: .events(result.events))
            } catch {
                setEventReadError(error.localizedDescription)
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Diagnostics could not be read: \(error.localizedDescription)")
                )
            }
        case .performanceTimeline(let limit):
            do {
                let records = try await diagnostics.recentPerformance(limit: min(max(limit, 0), 100))
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .performanceTimeline(Array(records.reversed()))
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Performance timeline could not be read: \(error.localizedDescription)")
                )
            }
        case .networkLatency(let sampleCount):
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .networkLatency(
                    await controller.sampleNetworkLatency(sampleCount: min(max(sampleCount, 1), 20)))
            )
        case .systemPressure:
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .systemPressure(await controller.sampleSystemPressure())
            )
        case .recoveryReceipts(let limit):
            do {
                let receipts = try await receiptStore.recentReceipts(limit: min(max(limit, 0), 3))
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .recoveryReceipts(receipts)
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Recovery history could not be read: \(error.localizedDescription)")
                )
            }
        case .profiles:
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .profiles(await engine.profileSummaries())
            )
        case .selectProfile(let identifier):
            do {
                let selected = try await engine.selectProfile(identifier: identifier)
                let report = TransitionReport(
                    phase: .idle,
                    message: "Selected profile: \(selected.name)."
                )
                return await transitionResponse(request, report: report)
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Profile was not changed: \(error.localizedDescription)")
                )
            }
        case .validateProfile(let profile):
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .profileValidation(profile.validationReport())
            )
        case .saveProfile(let profile):
            do {
                let report = try await engine.upsertProfile(profile)
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .profileValidation(report)
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Profile was not saved: \(error.localizedDescription)")
                )
            }
        case .deviceCalibration:
            return AgentResponse(
                requestIdentifier: request.identifier,
                payload: .deviceCalibration(await engine.deviceCalibrationDraft())
            )
        case .saveDeviceCalibration(let calibration):
            do {
                try await engine.saveDeviceCalibration(calibration)
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .deviceCalibration(calibration)
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Calibration was not saved: \(error.localizedDescription)")
                )
            }
        case .exportProfile(let identifier):
            do {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .profileExport(try await engine.exportProfile(identifier: identifier))
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Profile was not exported: \(error.localizedDescription)")
                )
            }
        case .previewProfileImport(let data):
            do {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .profileImportPreview(try await engine.previewProfileImport(data))
                )
            } catch {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Profile import is invalid: \(error.localizedDescription)")
                )
            }
        case .migrateLegacy:
            guard !(await engine.isIncidentModeActive()) else {
                return AgentResponse(
                    requestIdentifier: request.identifier,
                    payload: .failure("Exit Incident Mode before migrating the legacy watcher.")
                )
            }
            let startedAt = Date()
            return await transitionResponse(
                request, report: await controller.migrateLegacy(), operation: "migrate-legacy",
                startedAt: startedAt)
        }
    }

    private func transitionResponse(
        _ request: AgentRequest,
        report: TransitionReport,
        operation: String = "transition",
        startedAt: Date? = nil
    ) async -> AgentResponse {
        _ = await appendDiagnostic(report)
        await appendPerformance(
            operation: operation,
            startedAt: startedAt ?? report.occurredAt ?? Date(),
            report: report
        )
        logger.info("\(report.phase.rawValue, privacy: .public): \(report.message, privacy: .public)")
        return AgentResponse(requestIdentifier: request.identifier, payload: .transition(report))
    }

    private func monitorLoop() async {
        await loadPreferencesIfNeeded()
        var lastDriftCheck = Date.distantPast
        var lastHeartbeatWrite = Date.distantPast
        while !Task.isCancelled {
            var operation = "automatic-reconcile"
            var operationStartedAt = Date()
            var report = await engine.reconcile()
            if report.phase == .active,
                Date().timeIntervalSince(lastDriftCheck) >= 15
            {
                operation = "automatic-enforce"
                operationStartedAt = Date()
                report = await engine.enforceActive()
                lastDriftCheck = Date()
            }
            await recordIfChanged(report, operation: operation, startedAt: operationStartedAt)
            if Date().timeIntervalSince(lastHeartbeatWrite) >= 5 {
                await writeHeartbeat(report)
                lastHeartbeatWrite = Date()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func loadPreferencesIfNeeded() async {
        if let preferencesLoadTask {
            await preferencesLoadTask.value
            return
        }
        let engine = engine
        let logger = logger
        let task = Task {
            do {
                try await engine.loadRuntimePreferences()
            } catch {
                logger.error(
                    "Runtime preferences are unreadable; automatic transitions were paused: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        preferencesLoadTask = task
        await task.value
    }

    func recordIfChanged(
        _ report: TransitionReport,
        operation: String = "automatic-reconcile",
        startedAt: Date = Date()
    ) async {
        let signature =
            "\(report.phase.rawValue)\u{0}\(report.message)\u{0}"
            + report.results.map {
                "\($0.action)\u{0}\($0.target)\u{0}\($0.outcome.rawValue)\u{0}\($0.detail)"
            }.joined(separator: "\u{1}")
        guard signature != lastEventSignature else { return }
        guard await appendDiagnostic(report) else { return }
        await appendPerformance(operation: operation, startedAt: startedAt, report: report)
        lastEventSignature = signature
    }

    private func appendPerformance(
        operation: String,
        startedAt: Date,
        report: TransitionReport
    ) async {
        do {
            try await diagnostics.appendPerformance(
                SessionPerformanceRecord(
                    operation: operation,
                    startedAt: startedAt,
                    completedAt: Date(),
                    thermalState: Self.thermalState,
                    results: report.results
                ))
        } catch {
            setEventLogError(error.localizedDescription)
            logger.error("Performance timeline write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private func writeHeartbeat(_ report: TransitionReport) async {
        let now = Date()
        do {
            try await diagnostics.writeHeartbeat(
                AgentHeartbeat(
                    processIdentifier: getpid(),
                    startedAt: startedAt,
                    updatedAt: now,
                    phase: report.phase,
                    message: report.message
                ))
            heartbeatAt = now
            setHeartbeatError(nil)
        } catch {
            setHeartbeatError(error.localizedDescription)
            logger.error("Heartbeat write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendDiagnostic(_ report: TransitionReport) async -> Bool {
        do {
            try await diagnostics.append(report)
            setEventLogError(nil)
            return true
        } catch {
            setEventLogError(error.localizedDescription)
            logger.error("Event log write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func setEventLogError(_ error: String?) {
        diagnosticsHealth = DiagnosticsHealth(
            eventLogError: error,
            heartbeatError: diagnosticsHealth.heartbeatError,
            eventReadError: diagnosticsHealth.eventReadError
        )
    }

    private func setHeartbeatError(_ error: String?) {
        diagnosticsHealth = DiagnosticsHealth(
            eventLogError: diagnosticsHealth.eventLogError,
            heartbeatError: error,
            eventReadError: diagnosticsHealth.eventReadError
        )
    }

    private func setEventReadError(_ error: String?) {
        diagnosticsHealth = DiagnosticsHealth(
            eventLogError: diagnosticsHealth.eventLogError,
            heartbeatError: diagnosticsHealth.heartbeatError,
            eventReadError: error
        )
    }

    private func statusWithDiagnostics(_ status: CleanroomStatus) -> CleanroomStatus {
        CleanroomStatus(
            phase: status.phase,
            trigger: status.trigger,
            journal: status.journal,
            lastMessage: status.lastMessage,
            lastResults: status.lastResults,
            preflight: status.preflight,
            agentStartedAt: status.agentStartedAt,
            heartbeatAt: status.heartbeatAt,
            diagnosticsHealth: diagnosticsHealth,
            incidentMode: status.incidentMode,
            activeProfile: status.activeProfile,
            deviceCalibration: status.deviceCalibration
        )
    }
}
