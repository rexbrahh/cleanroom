import AppIntents
import CleanroomCore
import CleanroomProtocol

private enum ShortcutAgent {
    static func send(_ command: AgentCommand) async throws -> AgentPayload {
        try await CleanroomAgentClient().send(command).payload
    }
}

struct CleanroomStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Cleanroom Status"
    static let description = IntentDescription("Reports the authenticated Cleanroom agent status.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .status(let status) = try await ShortcutAgent.send(.status) else {
            return .result(dialog: "Cleanroom returned an unexpected status response.")
        }
        return .result(dialog: "Cleanroom is \(status.phase.rawValue). \(status.lastMessage)")
    }
}

struct CleanroomPreflightIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Cleanroom Preflight"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .preflight(let report) = try await ShortcutAgent.send(.preflight) else {
            return .result(dialog: "Cleanroom returned an unexpected preflight response.")
        }
        let readiness = report.isFreshAndComplete() ? report.highestSeverity.rawValue : "incomplete"
        return .result(dialog: "Cleanroom preflight is \(readiness).")
    }
}

struct CleanroomSafeLaunchIntent: AppIntent {
    static let title: LocalizedStringResource = "Safe Launch Game"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .transition(let report) = try await ShortcutAgent.send(.safeLaunch) else {
            return .result(dialog: "Cleanroom returned an unexpected launch response.")
        }
        return .result(dialog: IntentDialog(stringLiteral: report.message))
    }
}

struct CleanroomPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Cleanroom"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .transition(let report) = try await ShortcutAgent.send(.setPaused(true)) else {
            return .result(dialog: "Cleanroom returned an unexpected pause response.")
        }
        return .result(dialog: IntentDialog(stringLiteral: report.message))
    }
}

struct CleanroomRestoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Restore Cleanroom State"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .transition(let report) = try await ShortcutAgent.send(.restore) else {
            return .result(dialog: "Cleanroom returned an unexpected restore response.")
        }
        return .result(dialog: IntentDialog(stringLiteral: report.message))
    }
}

struct CleanroomAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CleanroomStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Cleanroom Status",
            systemImageName: "scope"
        )
        AppShortcut(
            intent: CleanroomPreflightIntent(),
            phrases: ["Run \(.applicationName) preflight"],
            shortTitle: "Cleanroom Preflight",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CleanroomSafeLaunchIntent(),
            phrases: ["Safe launch with \(.applicationName)"],
            shortTitle: "Safe Launch",
            systemImageName: "play.shield"
        )
        AppShortcut(
            intent: CleanroomPauseIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Cleanroom",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: CleanroomRestoreIntent(),
            phrases: ["Restore state with \(.applicationName)"],
            shortTitle: "Restore State",
            systemImageName: "arrow.uturn.backward.circle"
        )
    }
}
