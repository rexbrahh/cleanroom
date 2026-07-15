import CleanroomCore
import CleanroomProtocol
import Combine
import CryptoKit
import Foundation
import ServiceManagement

@MainActor
final class CleanroomViewModel: ObservableObject {
    @Published var status: CleanroomStatus?
    @Published var preflight: PreflightReport?
    @Published var operationInProgress = false
    @Published var connectionMessage = "Starting Cleanroom agent…"
    @Published var registrationMessage = "Checking background-agent registration…"
    @Published var presentingDiscardConfirmation = false
    @Published var recentEvents: [TransitionReport] = []

    private let client = CleanroomAgentClient()
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private var registrationInProgress = false
    private var lastRegistrationRepairAt = Date.distantPast
    private var statusPollCount = 0

    enum AgentHealth {
        case connecting
        case healthy
        case delayed
        case stale
        case unavailable
    }

    var iconName: String {
        switch status?.phase {
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

    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            await self?.refreshAgentRegistration()
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

    private func refreshAgentRegistration(force: Bool = false) async {
        guard !registrationInProgress else { return }
        registrationInProgress = true
        defer { registrationInProgress = false }

        let service = SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist")
        let digest = currentRegistrationDigest()
        let registeredDigest = UserDefaults.standard.string(forKey: "registeredAgentDigest")
        do {
            switch service.status {
            case .enabled:
                if force || digest == nil || registeredDigest != digest {
                    registrationMessage = "Refreshing background-agent registration…"
                    try await service.unregister()
                    try service.register()
                    if let digest { UserDefaults.standard.set(digest, forKey: "registeredAgentDigest") }
                    registrationMessage = "Background agent updated and enabled"
                } else {
                    registrationMessage = "Background agent enabled"
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
            statusPollCount += 1
            if statusPollCount == 1 || statusPollCount.isMultiple(of: 5) {
                await refreshEvents()
            }
        } catch {
            connectionMessage = "Agent unavailable: \(error.localizedDescription)"
            await client.invalidate()
            if Date().timeIntervalSince(lastRegistrationRepairAt) >= 30 {
                lastRegistrationRepairAt = Date()
                await refreshAgentRegistration(force: true)
            }
        }
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
}
