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

@MainActor
final class CleanroomViewModel: ObservableObject {
    @Published var status: CleanroomStatus?
    @Published var preflight: PreflightReport?
    @Published var operationInProgress = false
    @Published var connectionMessage = "Starting Cleanroom agent…"
    @Published var registrationMessage = "Checking background-agent registration…"
    @Published var presentingDiscardConfirmation = false
    @Published var recentEvents: [TransitionReport] = []
    @Published var notificationsEnabled: Bool
    @Published var notificationMessage = "Gameplay notifications are off"
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginMessage = "Checking menu-app launch at login…"

    private let client = CleanroomAgentClient()
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "app")
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private var registrationInProgress = false
    private var lastRegistrationRepairAt = Date.distantPast
    private var statusPollCount = 0
    private var previousPhase: CleanroomPhase?

    private static let notificationsPreferenceKey = "recoveryNotificationsEnabled"

    init() {
        // Keep ServiceManagement and UserNotifications IPC out of the app's
        // initialization path; both are refreshed asynchronously in start().
        notificationsEnabled = UserDefaults.standard.bool(
            forKey: Self.notificationsPreferenceKey
        )
    }

    enum AgentHealth {
        case connecting
        case healthy
        case delayed
        case stale
        case unavailable
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
        switch status?.phase {
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

    var sessionDetail: String {
        guard let journal = status?.journal else { return "No saved gameplay session" }
        let elapsed = max(0, Int(Date().timeIntervalSince(journal.createdAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        if hours > 0 { return "Session \(hours)h \(minutes)m · recovery armed" }
        return "Session \(minutes)m · recovery armed"
    }

    var preflightSummary: String {
        guard let findings = preflight?.findings else { return "Preflight has not run" }
        let critical = findings.count { $0.severity == .critical }
        let warnings = findings.count { $0.severity == .warning }
        if critical > 0 { return "\(critical) critical · \(warnings) warnings" }
        if warnings > 0 { return "\(warnings) warnings" }
        return "Ready"
    }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(version ?? "development") (\(build ?? "local"))"
    }

    func start() {
        guard !started else { return }
        started = true
        logger.notice("View model started; refreshing registration state")
        Task { [weak self] in
            await self?.refreshAgentRegistration()
            await self?.refreshNotificationAuthorization()
            await self?.refreshLaunchAtLoginStatus()
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
            await self?.refreshAgentRegistration(force: true)
        }
    }

    private func refreshAgentRegistration(force: Bool = false, forceReregister: Bool = false) async {
        guard !registrationInProgress else { return }
        registrationInProgress = true
        defer { registrationInProgress = false }

        let service = SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist")
        let digest = currentRegistrationDigest()
        let registeredDigest = UserDefaults.standard.string(forKey: "registeredAgentDigest")
        do {
            switch service.status {
            case .enabled:
                if digest == nil || registeredDigest != digest || forceReregister {
                    registrationMessage = "Refreshing background-agent registration…"
                    try await service.unregister()
                    try await Task.sleep(for: .seconds(1))
                    try service.register()
                    if let digest { UserDefaults.standard.set(digest, forKey: "registeredAgentDigest") }
                    registrationMessage = "Background agent updated and enabled"
                } else {
                    registrationMessage =
                        force
                        ? "Background agent is registered; connection recovery is pending"
                        : "Background agent enabled"
                }
            case .requiresApproval:
                registrationMessage = "Background agent requires approval in Login Items"
            case .notRegistered, .notFound:
                try service.register()
                if let digest { UserDefaults.standard.set(digest, forKey: "registeredAgentDigest") }
                registrationMessage =
                    service.status == .requiresApproval
                    ? "Background agent requires approval in Login Items"
                    : "Background agent registered"
            @unknown default:
                registrationMessage = "Background-agent status is unknown"
            }
        } catch {
            registrationMessage = "Agent registration failed: \(error.localizedDescription)"
            logger.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
        }
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
            self.status = status
            self.preflight = status.preflight ?? preflight
            connectionMessage = status.lastMessage
            handlePhaseTransition(to: status.phase)
            statusPollCount += 1
            if statusPollCount == 1 || statusPollCount.isMultiple(of: 5) {
                await refreshEvents()
            }
        } catch {
            let message = "Agent unavailable: \(error.localizedDescription)"
            if connectionMessage != message {
                logger.error("\(message, privacy: .public)")
            }
            connectionMessage = message
            await client.invalidate()
            if Date().timeIntervalSince(lastRegistrationRepairAt) >= 30 {
                lastRegistrationRepairAt = Date()
                await repairAgentLiveness()
            }
        }
    }

    /// The BTM registration can report "enabled" while launchd has no live
    /// job for the agent (e.g. the app bundle was replaced underneath the
    /// registration, leaving a crash-looping or unloaded job). A plain
    /// kickstart reloads a dead job; if launchd has no job at all, force a
    /// fresh SMAppService registration even when the binary digest is
    /// unchanged.
    private func repairAgentLiveness() async {
        let kickstart = await LocalCommandRunner().run(
            "/bin/launchctl",
            arguments: ["kickstart", "gui/\(getuid())/com.rex.cleanroom.agent"],
            timeout: 5
        )
        if kickstart.succeeded {
            logger.notice("Agent job kickstarted after a connection failure")
            return
        }
        logger.notice("Agent kickstart failed; forcing registration refresh")
        await refreshAgentRegistration(force: true, forceReregister: true)
    }

    func refreshEvents() async {
        do {
            let response = try await client.send(.recentEvents(limit: 30))
            guard case .events(let events) = response.payload else { return }
            recentEvents = events.reversed()
        } catch {
            await client.invalidate()
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
        perform(.recover(.discardJournal))
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
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        switch status {
        case .enabled:
            launchAtLoginMessage = "Menu-bar app launches at login"
        case .requiresApproval:
            launchAtLoginMessage = "Launch at login requires approval in Login Items"
        case .notRegistered, .notFound:
            launchAtLoginMessage = "Menu-bar launch at login is off"
        @unknown default:
            launchAtLoginMessage = "Menu-bar launch-at-login state is unknown"
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    // Unregister first: a stale login-item registration can be
                    // bound to an old app location (e.g. a dist/ build), which
                    // silently keeps launch-at-login pointed at the wrong copy.
                    try? await SMAppService.mainApp.unregister()
                    try SMAppService.mainApp.register()
                    logger.notice("Menu-app login item registered from \(Bundle.main.bundleURL.path, privacy: .public)")
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                refreshLaunchAtLoginStatus()
            } catch {
                refreshLaunchAtLoginStatus()
                launchAtLoginMessage = "Login-item change failed: \(error.localizedDescription)"
                logger.error("Login-item change failed: \(error.localizedDescription, privacy: .public)")
            }
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

    private func perform(_ command: AgentCommand) {
        guard !operationInProgress else { return }
        operationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { operationInProgress = false }
            do {
                let response = try await client.send(command)
                switch response.payload {
                case .status(let status):
                    self.status = status
                case .transition(let report):
                    connectionMessage = report.message
                    if let reportPreflight = report.preflight { preflight = reportPreflight }
                case .preflight(let report):
                    preflight = report
                    connectionMessage = "Competitive preflight completed."
                case .events(let events):
                    recentEvents = events.reversed()
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

    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.notificationsPreferenceKey)
            notificationMessage = "Notification permission is denied in System Settings"
        } else if notificationsEnabled {
            notificationMessage = "Recovery and degraded-state notifications are on"
        }
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
            let networkMutationPolicy: String
        }

        return try AgentCodec.encode(
            DiagnosticSnapshot(
                generatedAt: Date(),
                appVersion: appVersion,
                status: status,
                preflight: preflight,
                recentEvents: recentEvents,
                networkMutationPolicy: "read-only preflight; no network mutation"
            )
        )
    }
}
