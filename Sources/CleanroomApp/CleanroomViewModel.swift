import AppKit
import CleanroomCore
import CleanroomMac
import CleanroomProtocol
import Combine
import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

enum AgentLivenessRepairTrigger: Equatable {
    case automaticFailure
    case installerAuthorizedReplacement
    case userRequestedReplacement

    var permitsDestructiveReplacement: Bool {
        self != .automaticFailure
    }
}

struct SetupDoctorState: Equatable {
    let agentRegistered: Bool
    let xpcConnected: Bool
    let menuItemConfirmed: Bool

    var canComplete: Bool {
        agentRegistered && xpcConnected && menuItemConfirmed
    }
}

@MainActor
final class CleanroomViewModel: ObservableObject {
    @Published var status: CleanroomStatus?
    @Published var preflight: PreflightReport?
    @Published var operationInProgress = false
    @Published var connectionMessage = "Starting Cleanroom agent…"
    @Published var registrationMessage = "Checking background-agent registration…"
    @Published var agentRegistrationReady = false
    @Published var presentingDiscardConfirmation = false
    @Published var recentEvents: [TransitionReport] = []
    @Published var performanceTimeline: [SessionPerformanceRecord] = []
    @Published var networkLatency: NetworkLatencyReport?
    @Published var systemPressure: SystemPressureSample?
    @Published var recoveryHistory: [RecoveryReceipt] = []
    @Published var profiles: [CleanroomProfileSummary] = []
    @Published var profileDraftName = "Custom competitive profile"
    @Published var profileDraftTriggerBundleIdentifier = "com.example.Game"
    @Published var profileValidation: ProfileValidationReport?
    @Published var calibrationHardwareIdentifier = "unknown"
    @Published var calibrationPointerLinearEnabled = true
    @Published var calibrationDisplayRefreshRateHertz = 120
    @Published var calibrationRestoreDebounceSeconds = 5.0
    @Published var profileImportPreview: ProfileImportPreview?
    @Published var notificationsEnabled: Bool
    @Published var performanceAlertsEnabled: Bool
    @Published var thermalAlertThreshold: ThermalPressureLevel
    @Published var batteryAlertThreshold: Int
    @Published var notificationMessage = "Gameplay notifications are off"
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginDesired = true
    @Published var launchAtLoginMessage = "Checking menu-app launch at login…"
    @Published var setupDoctorVisible: Bool
    @Published var menuItemConfirmed: Bool
    @Published var preferredInstall = false
    @Published var leftoverCopyURLs: [URL] = []
    @Published var agentRequiresApproval = false
    @Published var agentUnreachableAfterRepair = false
    @Published var presentingLeftoverRemovalConfirmation = false
    @Published var presentingUninstallConfirmation = false
    @Published var uninstallPurgeData = false

    private let client = CleanroomAgentClient()
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "app")
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private var didRequestInputMonitoring = false
    private var registrationInProgress = false
    private var lastRegistrationRepairAt = Date.distantPast
    @Published private var lastLoginItemStatus: MenuLoginItemStatus = .notRegistered
    private var loginItemRegisteredThisSession = false
    private var becomeActiveObserver: NSObjectProtocol?
    private var statusPollCount = 0
    private var previousPhase: CleanroomPhase?
    private var pressureAlertGate = SystemPressureAlertGate()
    private let profileDraftIdentifier = "custom-\(UUID().uuidString.lowercased())"

    private static let notificationsPreferenceKey = "recoveryNotificationsEnabled"
    private static let performanceAlertsPreferenceKey = "performanceAlertsEnabled"
    private static let thermalThresholdPreferenceKey = "thermalAlertThreshold"
    private static let batteryThresholdPreferenceKey = "batteryAlertThreshold"
    private static let setupCompletedPreferenceKey = "setupDoctorCompleted"
    private static let menuItemConfirmedPreferenceKey = "setupDoctorMenuItemConfirmed"
    private static let launchAtLoginDesiredPreferenceKey = "launchAtLoginDesired"
    private static let installerReplacementAuthorizationURL =
        CleanroomPaths.applicationSupportDirectory.appendingPathComponent(
            "replace-agent-registration"
        )

    init() {
        // Keep ServiceManagement and UserNotifications IPC out of the app's
        // initialization path; both are refreshed asynchronously in start().
        notificationsEnabled = UserDefaults.standard.bool(
            forKey: Self.notificationsPreferenceKey
        )
        performanceAlertsEnabled = UserDefaults.standard.bool(
            forKey: Self.performanceAlertsPreferenceKey
        )
        let savedThermalThreshold = ThermalPressureLevel(
            rawValue: UserDefaults.standard.integer(forKey: Self.thermalThresholdPreferenceKey))
        thermalAlertThreshold =
            savedThermalThreshold == .critical || savedThermalThreshold == .serious
            ? savedThermalThreshold! : .serious
        let savedBatteryThreshold = UserDefaults.standard.integer(
            forKey: Self.batteryThresholdPreferenceKey)
        batteryAlertThreshold = savedBatteryThreshold == 0 ? 20 : savedBatteryThreshold
        setupDoctorVisible = !UserDefaults.standard.bool(forKey: Self.setupCompletedPreferenceKey)
        menuItemConfirmed = UserDefaults.standard.bool(forKey: Self.menuItemConfirmedPreferenceKey)
        let storedLaunchAtLogin: Bool? =
            UserDefaults.standard.object(forKey: Self.launchAtLoginDesiredPreferenceKey) == nil
            ? nil
            : UserDefaults.standard.bool(forKey: Self.launchAtLoginDesiredPreferenceKey)
        launchAtLoginDesired = RegistrationRepairPolicy.resolvedLaunchAtLoginDesired(
            stored: storedLaunchAtLogin
        )
        launchAtLoginEnabled = launchAtLoginDesired
        if storedLaunchAtLogin == nil {
            UserDefaults.standard.set(
                launchAtLoginDesired,
                forKey: Self.launchAtLoginDesiredPreferenceKey
            )
        }
        refreshInstallLocationHealth()
    }

    enum AgentHealth {
        case connecting
        case healthy
        case delayed
        case stale
        case unavailable
    }

    var agentConnected: Bool {
        status != nil && !connectionMessage.hasPrefix("Agent unavailable:")
    }

    var iconName: String {
        switch agentHealth {
        case .stale, .unavailable:
            return "exclamationmark.triangle.fill"
        case .connecting, .healthy, .delayed:
            break
        }
        return switch status?.phase {
        case .active: "scope"
        case .entering, .restoring: "arrow.triangle.2.circlepath"
        case .degraded: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .idle, nil: "scope"
        }
    }

    var phaseTitle: String {
        if status?.incidentMode == true { return "Incident Mode active" }
        return switch status?.phase {
        case .active: "Competitive mode active"
        case .entering: "Preparing competitive mode"
        case .restoring: "Restoring desktop state"
        case .degraded: "Recovery needs attention"
        case .paused: "Automatic control paused"
        case .idle: "Watching for Roblox"
        case nil: "Connecting to agent"
        }
    }

    var agentHealth: AgentHealth {
        guard status != nil else {
            return connectionMessage.hasPrefix("Agent unavailable") ? .unavailable : .connecting
        }
        guard agentConnected else { return .unavailable }
        guard let heartbeatAt = status?.heartbeatAt else { return .delayed }
        let age = Date().timeIntervalSince(heartbeatAt)
        if age <= 12 { return .healthy }
        if age <= 30 { return .delayed }
        return .stale
    }

    var agentHealthTitle: String {
        switch agentHealth {
        case .connecting: "Connecting"
        case .healthy: "Healthy"
        case .delayed: "Heartbeat delayed"
        case .stale: "Heartbeat stale"
        case .unavailable: "Unavailable"
        }
    }

    var diagnosticsHealthMessage: String? {
        guard let health = status?.diagnosticsHealth, !health.isHealthy else { return nil }
        return [health.eventLogError, health.heartbeatError, health.eventReadError]
            .compactMap { $0 }
            .joined(separator: "; ")
    }

    var setupDoctorState: SetupDoctorState {
        SetupDoctorState(
            agentRegistered: agentRegistrationReady,
            xpcConnected: agentConnected,
            menuItemConfirmed: menuItemConfirmed
        )
    }

    var launchAtLoginBound: Bool {
        lastLoginItemStatus == .enabled
    }

    var loginItemDecision: MenuLoginItemDecision {
        RegistrationRepairPolicy.loginItemDecision(
            desired: launchAtLoginDesired,
            status: lastLoginItemStatus,
            preferredInstall: preferredInstall
        )
    }

    var repairIssues: [RepairIssue] {
        RegistrationRepairPolicy.issues(
            preferredInstall: preferredInstall,
            leftoverCount: leftoverCopyURLs.count,
            loginItem: loginItemDecision,
            agentRequiresApproval: agentRequiresApproval,
            agentUnreachableAfterRepair: agentUnreachableAfterRepair
        )
    }

    var repairCardVisible: Bool {
        RegistrationRepairPolicy.shouldPresentRepairCard(
            setupDoctorVisible: setupDoctorVisible,
            issues: repairIssues
        )
    }

    func title(for issue: RepairIssue) -> String {
        switch issue {
        case .runningOutsideApplications:
            return "Install location"
        case .leftoverUserSpaceCopies:
            return "Leftover user-space copies"
        case .loginItemNeedsApproval:
            return "Login-item approval"
        case .loginItemNeedsRebind:
            return "Login-item binding"
        case .agentNeedsApproval:
            return "Background-agent approval"
        case .agentUnreachable:
            return "Background agent"
        }
    }

    func detail(for issue: RepairIssue) -> String {
        switch issue {
        case .runningOutsideApplications:
            return "Keep only \(RegistrationRepairPolicy.preferredBundlePath) and reopen that copy."
        case .leftoverUserSpaceCopies(let count):
            let names = leftoverCopyURLs.map(\.lastPathComponent).joined(separator: ", ")
            return
                "\(count) leftover \(count == 1 ? "copy" : "copies") in ~/Applications (\(names)) can steal login-item binding."
        case .loginItemNeedsApproval:
            return launchAtLoginMessage
        case .loginItemNeedsRebind:
            return launchAtLoginMessage
        case .agentNeedsApproval:
            return registrationMessage
        case .agentUnreachable:
            return connectionMessage
        }
    }

    var profileDraft: CleanroomProfile {
        let template = CleanroomProfile.phantomForces()
        return CleanroomProfile(
            identifier: profileDraftIdentifier,
            name: profileDraftName,
            triggerBundleIdentifier: profileDraftTriggerBundleIdentifier,
            applications: template.applications,
            services: template.services,
            processes: template.processes,
            preferences: template.preferences,
            processCPUWarningPercent: template.processCPUWarningPercent,
            processCPUCriticalPercent: template.processCPUCriticalPercent,
            blockAutomaticEntryOnCriticalPreflight: template.blockAutomaticEntryOnCriticalPreflight,
            suppressBuiltInTrackpadWhenLidOpen: template.suppressBuiltInTrackpadWhenLidOpen
        )
    }

    func confirmMenuItemVisible() {
        menuItemConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.menuItemConfirmedPreferenceKey)
    }

    func completeSetupDoctor() {
        guard setupDoctorState.canComplete else { return }
        setupDoctorVisible = false
        UserDefaults.standard.set(true, forKey: Self.setupCompletedPreferenceKey)
    }

    var sessionDetail: String {
        guard let journal = status?.journal else { return "No saved gameplay session" }
        let elapsed = max(0, Int(Date().timeIntervalSince(journal.createdAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        if hours > 0 { return "Session \(hours)h \(minutes)m · recovery armed" }
        return "Session \(minutes)m · recovery armed"
    }

    var preflightSummary: String {
        guard let preflight else { return "Preflight has not run" }
        guard preflight.isFreshAndComplete() else { return "Preflight incomplete or stale" }
        let findings = preflight.findings
        let critical = findings.count { $0.severity == .critical }
        let warnings = findings.count { $0.severity == .warning }
        if critical > 0 { return "\(critical) critical · \(warnings) warnings" }
        if warnings > 0 { return "\(warnings) warnings" }
        return preflight.isReady() ? "Ready" : "Preflight needs review"
    }

    var appVersion: String {
        CleanroomBuildIdentity.current.description
    }

    func start() {
        guard !started else { return }
        started = true
        if CommandLine.arguments.contains("--uninstall") {
            logger.notice("View model started in uninstall mode")
            Task { [weak self] in
                await self?.performUninstall(
                    purgeData: CommandLine.arguments.contains("--purge-data")
                )
            }
            return
        }
        logger.notice("View model started; refreshing registration state")
        Task { [weak self] in
            guard let self else { return }
            let replaceAgent = CommandLine.arguments.contains("--replace-agent")
            let digest = currentRegistrationDigest()
            let registeredDigest = UserDefaults.standard.string(forKey: "registeredAgentDigest")
            await refreshAgentRegistration(
                force: replaceAgent,
                trigger: Self.launchRegistrationTrigger(
                    userRequestedReplacement: replaceAgent,
                    installerMarkerAuthorized: installerReplacementIsAuthorized(),
                    digestChanged: digest != nil && digest != registeredDigest,
                    recoveryJournalExists: FileManager.default.fileExists(
                        atPath: FileRecoveryJournalStore().journalURL.path
                    )
                )
            )
            await refreshProfiles()
            await refreshCalibration()
            await refreshNotificationAuthorization()
            refreshInstallLocationHealth()
            await applyLoginItemRepairIfNeeded()
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRepairState()
            }
        }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func registerAgent() {
        Task { [weak self] in
            await self?.refreshAgentRegistration(
                force: true,
                trigger: .userRequestedReplacement
            )
        }
    }

    private func refreshAgentRegistration(
        force: Bool = false,
        trigger: AgentLivenessRepairTrigger = .automaticFailure
    ) async {
        guard !registrationInProgress else { return }
        registrationInProgress = true
        defer { registrationInProgress = false }

        let service = SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist")
        let digest = currentRegistrationDigest()
        let registeredDigest = UserDefaults.standard.string(forKey: "registeredAgentDigest")
        let digestChanged = digest != nil && digest != registeredDigest
        let journalExists = FileManager.default.fileExists(
            atPath: FileRecoveryJournalStore().journalURL.path
        )
        switch service.status {
        case .enabled:
            agentRequiresApproval = false
            if Self.shouldReplaceEnabledAgent(
                triggerPermitsDestructiveReplacement: trigger.permitsDestructiveReplacement,
                digestChanged: digestChanged,
                recoveryJournalExists: journalExists
            ) {
                await replaceEnabledAgent(service: service, digest: digest)
            } else if digestChanged {
                registrationMessage =
                    "Background agent update is waiting until the current session is restored"
                agentRegistrationReady = true
            } else {
                registrationMessage =
                    force
                    ? "Background agent is registered; connection recovery is pending"
                    : "Background agent enabled"
                agentRegistrationReady = true
            }
        case .requiresApproval:
            agentRequiresApproval = true
            registrationMessage = "Background agent requires approval in Login Items"
            agentRegistrationReady = false
        case .notRegistered, .notFound:
            agentRequiresApproval = false
            await replaceEnabledAgent(service: service, digest: digest)
        @unknown default:
            agentRequiresApproval = false
            registrationMessage = "Background-agent status is unknown"
            agentRegistrationReady = false
        }
    }

    /// Unregister while SMAppService still reports `.enabled`, then register and
    /// wait until XPC answers. launchd EX_CONFIG (78) means the job is enabled
    /// but cannot spawn the new CDHash; bootout-first leaves that LWCR stale.
    private func replaceEnabledAgent(service: SMAppService, digest: String?) async {
        agentRegistrationReady = false
        registrationMessage = "Refreshing background-agent registration…"
        for _ in 1...2 {
            do {
                try await Self.unregisterLaunchAgent()
            } catch {
                logger.error(
                    "Agent unregister before recycle failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            try? await Task.sleep(for: .seconds(1))
            do {
                try service.register()
            } catch {
                registrationMessage = "Agent registration failed: \(error.localizedDescription)"
                logger.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            lastRegistrationRepairAt = Date()
            if await waitUntilAgentAnswers(timeout: 8) {
                if let digest { UserDefaults.standard.set(digest, forKey: "registeredAgentDigest") }
                registrationMessage = "Background agent updated and enabled"
                agentRegistrationReady = true
                return
            }
        }
        registrationMessage =
            "Background agent is registered but not answering; use Replace Agent Registration"
        agentRegistrationReady = false
    }

    nonisolated private static func unregisterLaunchAgent() async throws {
        try await SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist").unregister()
    }

    nonisolated private static func unregisterMainApp() async throws {
        try await SMAppService.mainApp.unregister()
    }

    private func waitUntilAgentAnswers(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeAgent() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return await probeAgent()
    }

    nonisolated static func installerReplacementIsAuthorized(
        markerBuild: String?,
        currentBuild: String
    ) -> Bool {
        markerBuild?.trimmingCharacters(in: .whitespacesAndNewlines) == currentBuild
    }

    nonisolated static func launchRegistrationTrigger(
        userRequestedReplacement: Bool,
        installerMarkerAuthorized: Bool,
        digestChanged: Bool,
        recoveryJournalExists: Bool
    ) -> AgentLivenessRepairTrigger {
        if userRequestedReplacement { return .userRequestedReplacement }
        if installerMarkerAuthorized { return .installerAuthorizedReplacement }
        if digestChanged && !recoveryJournalExists { return .installerAuthorizedReplacement }
        return .automaticFailure
    }

    nonisolated static func shouldReplaceEnabledAgent(
        triggerPermitsDestructiveReplacement: Bool,
        digestChanged: Bool,
        recoveryJournalExists: Bool
    ) -> Bool {
        if triggerPermitsDestructiveReplacement { return true }
        return digestChanged && !recoveryJournalExists
    }

    nonisolated static func shouldClearInstallerReplacementAuthorization(
        agentBuild: CleanroomBuildIdentity?,
        currentBuild: CleanroomBuildIdentity,
        markerBuild: String?
    ) -> Bool {
        agentBuild == currentBuild
            && installerReplacementIsAuthorized(
                markerBuild: markerBuild,
                currentBuild: currentBuild.build
            )
    }

    nonisolated static func shouldAttemptAutomaticLivenessRepair(
        registrationInProgress: Bool,
        elapsedSinceRegistrationRepair: TimeInterval
    ) -> Bool {
        !registrationInProgress && elapsedSinceRegistrationRepair >= 30
    }

    private func installerReplacementIsAuthorized() -> Bool {
        let marker = try? String(
            contentsOf: Self.installerReplacementAuthorizationURL,
            encoding: .utf8
        )
        return Self.installerReplacementIsAuthorized(
            markerBuild: marker,
            currentBuild: CleanroomBuildIdentity.current.build
        )
    }

    private func clearInstallerReplacementAuthorization() {
        guard FileManager.default.fileExists(atPath: Self.installerReplacementAuthorizationURL.path)
        else { return }
        try? FileManager.default.removeItem(at: Self.installerReplacementAuthorizationURL)
    }

    private func currentRegistrationDigest() -> String? {
        let bundleURL = Bundle.main.bundleURL
        let urls = [
            Bundle.main.executableURL,
            bundleURL.appendingPathComponent("Contents/Library/LaunchServices/cleanroom-agent"),
            bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.rex.cleanroom.agent.plist"),
            bundleURL.appendingPathComponent("Contents/Info.plist"),
            bundleURL.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
        ].compactMap { $0 }

        var hasher = SHA256()
        var hashedFileCount = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            hasher.update(data: data)
            hashedFileCount += 1
        }
        guard hashedFileCount >= 2 else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshStatus() async {
        do {
            let response = try await client.send(.status)
            guard case .status(let status) = response.payload else { return }
            // Publish only on change: assigning @Published values fires
            // objectWillChange even when the value is identical, which would
            // re-render the menu and dashboard on every 2s poll.
            if self.status != status {
                self.status = status
            }
            if agentUnreachableAfterRepair {
                agentUnreachableAfterRepair = false
            }
            if Self.shouldClearInstallerReplacementAuthorization(
                agentBuild: response.agentBuild,
                currentBuild: CleanroomBuildIdentity.current,
                markerBuild: try? String(
                    contentsOf: Self.installerReplacementAuthorizationURL,
                    encoding: .utf8
                )
            ) {
                clearInstallerReplacementAuthorization()
            }
            let resolvedPreflight = status.preflight ?? preflight
            if self.preflight != resolvedPreflight {
                self.preflight = resolvedPreflight
            }
            requestInputMonitoringIfNeeded(from: resolvedPreflight)
            if connectionMessage != status.lastMessage {
                connectionMessage = status.lastMessage
            }
            handlePhaseTransition(to: status.phase)
            statusPollCount += 1
            if statusPollCount == 1 || statusPollCount.isMultiple(of: 5) {
                refreshLaunchAtLoginStatus()
                await refreshEvents()
                await refreshRecoveryHistory()
                await refreshPerformanceTimeline()
                if status.phase == .active {
                    await refreshSystemPressure()
                } else {
                    pressureAlertGate = SystemPressureAlertGate()
                }
            }
        } catch {
            let message = "Agent unavailable: \(error.localizedDescription)"
            if connectionMessage != message {
                logger.error("\(message, privacy: .public)")
            }
            connectionMessage = message
            await client.invalidate()
            if status?.incidentMode == true { return }
            if Self.shouldAttemptAutomaticLivenessRepair(
                registrationInProgress: registrationInProgress,
                elapsedSinceRegistrationRepair: Date().timeIntervalSince(lastRegistrationRepairAt)
            ) {
                lastRegistrationRepairAt = Date()
                await repairAgentLiveness()
            }
        }
    }

    /// Kickstart first. EX_CONFIG jobs stay silent after kickstart, so recycle
    /// SMAppService when no recovery journal is protecting live state.
    private func repairAgentLiveness() async {
        _ = await LocalCommandRunner().run(
            "/bin/launchctl",
            arguments: ["kickstart", "gui/\(getuid())/com.rex.cleanroom.agent"],
            timeout: 5
        )
        if await probeAgent() {
            agentUnreachableAfterRepair = false
            logger.notice("Agent answered after kickstart; no re-registration needed")
            return
        }
        let journalExists = FileManager.default.fileExists(
            atPath: FileRecoveryJournalStore().journalURL.path
        )
        if journalExists {
            agentUnreachableAfterRepair = true
            registrationMessage =
                "Agent unreachable after non-destructive repair; replace its registration only when no transition is running"
            logger.error("Agent still unreachable after non-destructive kickstart")
            return
        }
        await refreshAgentRegistration(
            force: true,
            trigger: .installerAuthorizedReplacement
        )
        agentUnreachableAfterRepair = !(await probeAgent())
    }

    private func probeAgent() async -> Bool {
        do {
            let response = try await client.send(.status)
            if case .status = response.payload { return true }
        } catch {
            await client.invalidate()
        }
        return false
    }

    /// The polling cadence means the menu can show slightly stale state when
    /// it opens; refresh immediately so what the user sees is never behind.
    func menuOpened() {
        refreshRepairState()
        Task { [weak self] in
            await self?.refreshStatus()
        }
    }

    func refreshRepairState() {
        refreshInstallLocationHealth()
        refreshLaunchAtLoginStatus()
        refreshAgentApprovalStatus()
    }

    func refreshInstallLocationHealth() {
        preferredInstall = RegistrationRepairPolicy.isPreferredInstall(
            bundleURL: Bundle.main.bundleURL
        )
        leftoverCopyURLs = RegistrationRepairPolicy.leftoverUserSpaceCopies(
            in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            runningBundleURL: Bundle.main.bundleURL
        )
    }

    func refreshEvents() async {
        do {
            let response = try await client.send(.recentEvents(limit: 30))
            guard case .events(let events) = response.payload else { return }
            let ordered = events.reversed() as [TransitionReport]
            if recentEvents != ordered {
                recentEvents = ordered
            }
        } catch {
            await client.invalidate()
        }
    }

    func refreshRecoveryHistory() async {
        do {
            let response = try await client.send(.recoveryReceipts(limit: 3))
            guard case .recoveryReceipts(let receipts) = response.payload else { return }
            if recoveryHistory != receipts { recoveryHistory = receipts }
        } catch {
            await client.invalidate()
        }
    }

    func refreshPerformanceTimeline() async {
        do {
            let response = try await client.send(.performanceTimeline(limit: 30))
            guard case .performanceTimeline(let records) = response.payload else { return }
            if performanceTimeline != records { performanceTimeline = records }
        } catch {
            await client.invalidate()
        }
    }

    func sampleNetworkLatency() {
        perform(.networkLatency(sampleCount: 5))
    }

    func performGlobalHotKey(_ action: GlobalHotKeyAction) {
        switch action {
        case .status:
            Task { await refreshStatus() }
        case .preflight:
            runPreflight()
        case .safeLaunch:
            safeLaunch()
        case .togglePause:
            togglePause()
        case .restore:
            restore()
        }
    }

    func refreshSystemPressure() async {
        do {
            let response = try await client.send(.systemPressure)
            guard case .systemPressure(let sample) = response.payload else { return }
            systemPressure = sample
            guard performanceAlertsEnabled else { return }
            let thresholds = SystemAlertThresholds(
                thermal: thermalAlertThreshold,
                batteryPercent: batteryAlertThreshold
            )
            for alert in pressureAlertGate.crossings(for: sample, thresholds: thresholds) {
                switch alert {
                case .thermal:
                    deliverNotification(
                        title: "Thermal pressure threshold reached",
                        body: "macOS reports \(sample.thermal) thermal pressure during this session."
                    )
                case .battery:
                    deliverNotification(
                        title: "Battery threshold reached",
                        body: "Battery is at \(sample.batteryPercent ?? 0)% and is not on AC power."
                    )
                }
            }
        } catch {
            await client.invalidate()
        }
    }

    func setPerformanceAlertsEnabled(_ enabled: Bool) {
        if !enabled {
            performanceAlertsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.performanceAlertsPreferenceKey)
            pressureAlertGate = SystemPressureAlertGate()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted =
                (try? await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound])) ?? false
            performanceAlertsEnabled = granted
            UserDefaults.standard.set(granted, forKey: Self.performanceAlertsPreferenceKey)
        }
    }

    func savePerformanceAlertThresholds() {
        UserDefaults.standard.set(
            thermalAlertThreshold.rawValue, forKey: Self.thermalThresholdPreferenceKey)
        UserDefaults.standard.set(batteryAlertThreshold, forKey: Self.batteryThresholdPreferenceKey)
        pressureAlertGate = SystemPressureAlertGate()
    }

    func refreshProfiles() async {
        do {
            let response = try await client.send(.profiles)
            guard case .profiles(let profiles) = response.payload else { return }
            if self.profiles != profiles { self.profiles = profiles }
        } catch {
            await client.invalidate()
        }
    }

    func selectProfile(_ identifier: String) {
        perform(.selectProfile(identifier))
    }

    func validateProfileDraft() {
        perform(.validateProfile(profileDraft))
    }

    func saveProfileDraft() {
        perform(.saveProfile(profileDraft))
    }

    func refreshCalibration() async {
        do {
            let response = try await client.send(.deviceCalibration)
            guard case .deviceCalibration(let calibration) = response.payload,
                let calibration
            else { return }
            applyCalibration(calibration)
        } catch {
            await client.invalidate()
        }
    }

    func saveCalibration() {
        perform(
            .saveDeviceCalibration(
                DeviceCalibration(
                    hardwareIdentifier: calibrationHardwareIdentifier,
                    pointerLinearEnabled: calibrationPointerLinearEnabled,
                    preferredDisplayRefreshRateHertz: calibrationDisplayRefreshRateHertz,
                    automaticRestoreDebounceSeconds: calibrationRestoreDebounceSeconds
                )
            )
        )
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Preview Cleanroom Profile Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            perform(.previewProfileImport(data))
        } catch {
            connectionMessage = "Profile import could not be read: \(error.localizedDescription)"
        }
    }

    func confirmProfileImport() {
        guard let preview = profileImportPreview, preview.canImport else { return }
        perform(.saveProfile(preview.profile))
    }

    func exportActiveProfile() {
        guard let identifier = status?.activeProfile?.identifier else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.send(.exportProfile(identifier))
                guard case .profileExport(let data) = response.payload else { return }
                let panel = NSSavePanel()
                panel.title = "Export Cleanroom Profile"
                panel.nameFieldStringValue = "\(identifier).cleanroom-profile.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                connectionMessage = "Profile exported to \(url.lastPathComponent)."
            } catch {
                connectionMessage = "Profile export failed: \(error.localizedDescription)"
            }
        }
    }

    func runPreflight() {
        perform(.preflight)
    }

    func enter() {
        perform(.enter(force: false))
    }

    func restore() {
        perform(.restore)
    }

    func safeLaunch() {
        perform(.safeLaunch)
    }

    func togglePause() {
        perform(.setPaused(status?.phase != .paused))
    }

    func retryEntry() {
        perform(.recover(.retryEntry))
    }

    func retryRestore() {
        perform(.recover(.retryRestore))
    }

    func discardJournal() {
        perform(.recover(.discardJournal), destructiveRecoveryConfirmed: true)
    }

    func enterIncidentMode() {
        perform(.setIncidentMode(true))
        Task { [weak self] in
            await self?.refreshEvents()
            await self?.refreshRecoveryHistory()
        }
    }

    func exitIncidentMode() {
        perform(.setIncidentMode(false))
    }

    func migrateLegacy() {
        perform(.migrateLegacy)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        if !enabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.notificationsPreferenceKey)
            notificationMessage = "Gameplay notifications are off"
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                )
                notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: Self.notificationsPreferenceKey)
                notificationMessage =
                    granted
                    ? "Recovery and degraded-state notifications are on"
                    : "Notification permission was denied"
            } catch {
                notificationsEnabled = false
                UserDefaults.standard.set(false, forKey: Self.notificationsPreferenceKey)
                notificationMessage = "Notification setup failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let observed = Self.menuLoginItemStatus(from: SMAppService.mainApp.status)
        lastLoginItemStatus = RegistrationRepairPolicy.coalesceLoginItemStatus(
            observed: observed,
            desired: launchAtLoginDesired,
            registeredThisSession: loginItemRegisteredThisSession
        )
        let decision = RegistrationRepairPolicy.loginItemDecision(
            desired: launchAtLoginDesired,
            status: lastLoginItemStatus,
            preferredInstall: preferredInstall
        )
        launchAtLoginEnabled = decision.toggleOn
        launchAtLoginMessage = decision.message
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        persistLaunchAtLoginDesired(enabled)
        Task { [weak self] in
            guard let self else { return }
            if enabled {
                if !preferredInstall {
                    refreshLaunchAtLoginStatus()
                    return
                }
                await rebindLoginItem(reason: "user")
            } else {
                do {
                    try await Self.unregisterMainApp()
                    loginItemRegisteredThisSession = false
                    await waitForLoginItemMutation(.unregister)
                } catch {
                    refreshLaunchAtLoginStatus()
                    launchAtLoginMessage = "Login-item change failed: \(error.localizedDescription)"
                    logger.error("Login-item change failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func uninstallCleanroom() {
        let purge = uninstallPurgeData
        Task { [weak self] in
            await self?.performUninstall(purgeData: purge)
        }
    }

    func removeLeftoverCopies() {
        let running = RegistrationRepairPolicy.standardized(Bundle.main.bundleURL)
        let urls = leftoverCopyURLs.filter {
            RegistrationRepairPolicy.standardized($0) != running
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.connectionMessage =
                        "Leftover copies could not be moved to Trash: \(error.localizedDescription)"
                } else {
                    self.relinkCLIIfNeeded()
                    self.connectionMessage = "Moved leftover Cleanroom copies to Trash."
                }
                self.refreshInstallLocationHealth()
            }
        }
    }

    private func relinkCLIIfNeeded() {
        let fileManager = FileManager.default
        let preferred = URL(fileURLWithPath: RegistrationRepairPolicy.preferredBundlePath)
            .appendingPathComponent("Contents/Resources/cleanroomctl")
        guard fileManager.isExecutableFile(atPath: preferred.path) else { return }
        let link = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("bin/cleanroomctl")
        let hasLink =
            fileManager.fileExists(atPath: link.path)
            || ((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil)
        guard hasLink else { return }
        do {
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: preferred)
        } catch {
            logger.error(
                "cleanroomctl retarget failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performUninstall(purgeData: Bool) async {
        refreshInstallLocationHealth()
        let plan = currentUninstallPlan(purgeData: purgeData)
        logger.notice("Uninstall started; purge=\(purgeData, privacy: .public)")
        for step in plan.steps {
            switch step {
            case .unregisterAgent:
                try? await Self.unregisterLaunchAgent()
            case .unregisterLoginItem:
                try? await Self.unregisterMainApp()
            case .bootoutAgent:
                _ = await LocalCommandRunner().run(
                    "/bin/launchctl",
                    arguments: ["bootout", "gui/\(getuid())/com.rex.cleanroom.agent"],
                    timeout: 5
                )
            case .trashBundles:
                await trashUninstallBundles(plan.bundlesToTrash)
            case .removeExtraFiles:
                removeUninstallFiles(plan.extraRemovals, purgeDefaults: purgeData)
            case .quitApp:
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func currentUninstallPlan(purgeData: Bool) -> UninstallPlan {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let cli = home.appendingPathComponent("bin/cleanroomctl")
        let destination = try? fileManager.destinationOfSymbolicLink(atPath: cli.path)
        let hasCLI = destination != nil || fileManager.fileExists(atPath: cli.path)
        let legacy = home.appendingPathComponent(
            "Library/LaunchAgents/com.rex.cleanroom.agent.plist"
        )
        let previousDir = CleanroomPaths.applicationSupportDirectory.appendingPathComponent(
            "previous"
        )
        return UninstallPolicy.plan(
            runningBundleURL: Bundle.main.bundleURL,
            preferredBundleURL: URL(fileURLWithPath: RegistrationRepairPolicy.preferredBundlePath),
            leftoverCopies: leftoverCopyURLs,
            previousBackups: UninstallPolicy.previousInstallBackups(in: previousDir),
            cliLink: hasCLI ? cli : nil,
            cliLinkPointsAtCleanroom: UninstallPolicy.shouldRemoveCLILink(destination: destination),
            legacyLaunchAgentPlist: fileManager.fileExists(atPath: legacy.path) ? legacy : nil,
            supportDirectory: CleanroomPaths.applicationSupportDirectory,
            purgeData: purgeData
        )
    }

    private func trashUninstallBundles(_ urls: [URL]) async {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(existing) { _, _ in
                continuation.resume()
            }
        }
    }

    private func removeUninstallFiles(_ urls: [URL], purgeDefaults: Bool) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        if purgeDefaults {
            UserDefaults.standard.removePersistentDomain(forName: "com.rex.cleanroom")
        }
    }

    private func persistLaunchAtLoginDesired(_ enabled: Bool) {
        launchAtLoginDesired = enabled
        launchAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginDesiredPreferenceKey)
    }

    private func applyLoginItemRepairIfNeeded() async {
        refreshLaunchAtLoginStatus()
        switch loginItemDecision.action {
        case .rebindCurrentBundle:
            await rebindLoginItem(reason: "automatic")
        case .unbindCurrentBundle:
            do {
                try await Self.unregisterMainApp()
            } catch {
                logger.error(
                    "Automatic login-item unbind failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            refreshLaunchAtLoginStatus()
        case .requestApproval, .none:
            break
        }
    }

    private func rebindLoginItem(reason: String) async {
        do {
            // Unregister first: a stale login-item registration can be bound
            // to an old app location, which keeps System Settings showing
            // Cleanroom while this copy reports the toggle as off.
            try? await Self.unregisterMainApp()
            try SMAppService.mainApp.register()
            loginItemRegisteredThisSession = true
            logger.notice(
                "Menu-app login item rebound (\(reason, privacy: .public)) from \(Bundle.main.bundleURL.path, privacy: .public)"
            )
            await waitForLoginItemMutation(.register)
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "Login-item change failed: \(error.localizedDescription)"
            logger.error("Login-item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func waitForLoginItemMutation(_ mutation: LoginItemMutation) async {
        let started = Date()
        while !Task.isCancelled {
            let observed = Self.menuLoginItemStatus(from: SMAppService.mainApp.status)
            let resolution = RegistrationRepairPolicy.resolvedStatusAfterMutation(
                mutation: mutation,
                observed: observed,
                elapsed: Date().timeIntervalSince(started)
            )
            lastLoginItemStatus = resolution.status
            let decision = RegistrationRepairPolicy.loginItemDecision(
                desired: launchAtLoginDesired,
                status: lastLoginItemStatus,
                preferredInstall: preferredInstall
            )
            launchAtLoginEnabled = decision.toggleOn
            launchAtLoginMessage = decision.message
            if !resolution.keepWaiting { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func refreshAgentApprovalStatus() {
        let status = SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist").status
        agentRequiresApproval = status == .requiresApproval
        if status == .requiresApproval {
            registrationMessage = "Background agent requires approval in Login Items"
            agentRegistrationReady = false
        }
    }

    private static func menuLoginItemStatus(from status: SMAppService.Status) -> MenuLoginItemStatus {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .notRegistered
        @unknown default:
            return .unknown
        }
    }

    func copyDiagnostics() {
        do {
            let text = String(decoding: try diagnosticData(), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            connectionMessage = "Diagnostics copied to the clipboard."
        } catch {
            connectionMessage = "Diagnostics copy failed: \(error.localizedDescription)"
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Cleanroom Diagnostics"
        panel.nameFieldStringValue = "Cleanroom-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticData().write(to: url, options: .atomic)
            connectionMessage = "Diagnostics exported to \(url.lastPathComponent)."
        } catch {
            connectionMessage = "Diagnostics export failed: \(error.localizedDescription)"
        }
    }

    func exportSupportBundle() {
        let panel = NSSavePanel()
        panel.title = "Export Redacted Cleanroom Support Bundle"
        panel.nameFieldStringValue = "Cleanroom-support.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { operationInProgress = false }
            await refreshStatus()
            await refreshEvents()
            await refreshRecoveryHistory()
            await refreshPerformanceTimeline()
            let document = SupportBundleRedactor.makeDocument(
                appVersion: appVersion,
                status: status,
                preflight: preflight,
                events: recentEvents,
                receipts: recoveryHistory,
                performance: performanceTimeline
            )
            do {
                try await SupportBundleArchive.write(document, to: url)
                connectionMessage = "Redacted local support bundle exported; nothing was submitted."
            } catch {
                connectionMessage = "Support bundle export failed: \(error.localizedDescription)"
            }
        }
    }

    private func perform(
        _ command: AgentCommand,
        destructiveRecoveryConfirmed: Bool = false
    ) {
        guard !operationInProgress else { return }
        operationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { operationInProgress = false }
            do {
                let response = try await client.send(
                    command,
                    destructiveRecoveryConfirmed: destructiveRecoveryConfirmed
                )
                switch response.payload {
                case .handshake(let handshake):
                    connectionMessage = handshake.incompatibility ?? "Agent capabilities negotiated."
                case .status(let status):
                    self.status = status
                case .transition(let report):
                    connectionMessage = report.message
                    if let reportPreflight = report.preflight { preflight = reportPreflight }
                case .preflight(let report):
                    preflight = report
                    connectionMessage = "Competitive preflight completed."
                    requestInputMonitoringIfNeeded(from: report)
                case .events(let events):
                    recentEvents = events.reversed()
                case .performanceTimeline(let records):
                    performanceTimeline = records
                case .networkLatency(let report):
                    networkLatency = report
                    connectionMessage = report.error ?? "Read-only latency sample completed."
                case .systemPressure(let sample):
                    systemPressure = sample
                case .recoveryReceipts(let receipts):
                    recoveryHistory = receipts
                case .profiles(let profiles):
                    self.profiles = profiles
                case .profileValidation(let report):
                    profileValidation = report
                    connectionMessage =
                        report.isValid
                        ? "Profile validation passed with \(report.mutations.count) mutation targets."
                        : report.errors.joined(separator: " ")
                    await refreshProfiles()
                case .deviceCalibration(let calibration):
                    if let calibration { applyCalibration(calibration) }
                    connectionMessage = "Device calibration saved for this Mac."
                case .profileExport:
                    break
                case .profileImportPreview(let preview):
                    profileImportPreview = preview
                    connectionMessage =
                        preview.canImport
                        ? "Profile import is valid; review the mutation diff before confirming."
                        : preview.validation.errors.joined(separator: " ")
                case .requestInProgress:
                    connectionMessage = "The request is still running; its operation was not started twice."
                case .failure(let message):
                    connectionMessage = message
                }
                await refreshStatus()
            } catch {
                connectionMessage = error.localizedDescription
                await client.invalidate()
            }
        }
    }

    private func requestInputMonitoringIfNeeded(from report: PreflightReport?) {
        guard let report, !didRequestInputMonitoring else { return }
        guard report.findings.contains(where: { $0.id == "input-monitoring-missing" }) else { return }
        didRequestInputMonitoring = true
        _ = ListenEventAccess.request()
    }

    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            notificationsEnabled = false
            performanceAlertsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.notificationsPreferenceKey)
            UserDefaults.standard.set(false, forKey: Self.performanceAlertsPreferenceKey)
            notificationMessage = "Notification permission is denied in System Settings"
        } else if notificationsEnabled {
            notificationMessage = "Recovery and degraded-state notifications are on"
        }
    }

    private func applyCalibration(_ calibration: DeviceCalibration) {
        calibrationHardwareIdentifier = calibration.hardwareIdentifier
        calibrationPointerLinearEnabled = calibration.pointerLinearEnabled
        calibrationDisplayRefreshRateHertz = calibration.preferredDisplayRefreshRateHertz
        calibrationRestoreDebounceSeconds = calibration.automaticRestoreDebounceSeconds
    }

    private func handlePhaseTransition(to phase: CleanroomPhase) {
        defer { previousPhase = phase }
        guard let previousPhase, previousPhase != phase, notificationsEnabled else { return }

        switch phase {
        case .degraded:
            deliverNotification(
                title: "Cleanroom needs attention",
                body: status?.lastMessage ?? "Recovery or entry verification needs attention."
            )
        case .idle where previousPhase == .restoring || previousPhase == .active:
            deliverNotification(
                title: "Cleanroom restored",
                body: "Saved desktop and input state has been restored."
            )
        case .idle, .entering, .active, .restoring, .paused:
            break
        }
    }

    private func deliverNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.notificationMessage = "Notification delivery failed: \(error.localizedDescription)"
            }
        }
    }

    private func diagnosticData() throws -> Data {
        struct DiagnosticSnapshot: Encodable {
            let generatedAt: Date
            let appVersion: String
            let status: CleanroomStatus?
            let preflight: PreflightReport?
            let recentEvents: [TransitionReport]
            let performanceTimeline: [SessionPerformanceRecord]
            let recoveryHistory: [RecoveryReceipt]
            let networkMutationPolicy: String
        }

        return try AgentCodec.encode(
            DiagnosticSnapshot(
                generatedAt: Date(),
                appVersion: appVersion,
                status: status,
                preflight: preflight,
                recentEvents: recentEvents,
                performanceTimeline: performanceTimeline,
                recoveryHistory: recoveryHistory,
                networkMutationPolicy: "read-only preflight; no network mutation"
            )
        )
    }
}
