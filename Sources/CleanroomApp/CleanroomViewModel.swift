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

    private let client = CleanroomAgentClient()
    private var pollingTask: Task<Void, Never>?
    private var started = false

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
        let service = SMAppService.agent(plistName: "com.rex.cleanroom.agent.plist")
        let digest = currentAgentDigest()
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

    private func currentAgentDigest() -> String? {
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/cleanroom-agent")
        guard let data = try? Data(contentsOf: agentURL, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        } catch {
            connectionMessage = "Agent unavailable: \(error.localizedDescription)"
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
                case .events, .failure:
                    break
                }
                await refreshStatus()
            } catch {
                connectionMessage = error.localizedDescription
                await client.invalidate()
            }
        }
    }
}
