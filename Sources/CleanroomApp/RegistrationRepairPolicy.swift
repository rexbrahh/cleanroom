import Foundation

enum MenuLoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case unknown
}

enum MenuLoginItemAction: Equatable, Sendable {
    case none
    case rebindCurrentBundle
    case unbindCurrentBundle
    case requestApproval
}

struct MenuLoginItemDecision: Equatable, Sendable {
    var action: MenuLoginItemAction
    var toggleOn: Bool
    var message: String
}

enum LoginItemMutation: Equatable, Sendable {
    case register
    case unregister
}

struct LoginItemMutationResolution: Equatable, Sendable {
    var status: MenuLoginItemStatus
    var keepWaiting: Bool
}

enum RepairIssue: Equatable, Hashable, Sendable {
    case runningOutsideApplications
    case leftoverUserSpaceCopies(Int)
    case loginItemNeedsApproval
    case loginItemNeedsRebind
    case agentNeedsApproval
    case agentUnreachable
}

enum RegistrationRepairPolicy {
    static let preferredBundlePath = "/Applications/Cleanroom.app"

    static func resolvedLaunchAtLoginDesired(stored: Bool?) -> Bool {
        stored ?? true
    }

    static func standardized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isPreferredInstall(
        bundleURL: URL,
        preferredPath: String = preferredBundlePath
    ) -> Bool {
        standardized(bundleURL) == standardized(URL(fileURLWithPath: preferredPath))
    }

    static func isLeftoverCopyName(_ name: String) -> Bool {
        if name == "Cleanroom.app" { return true }
        return name.hasPrefix("Cleanroom.previous.") && name.hasSuffix(".app")
    }

    static func leftoverUserSpaceCopies(
        in directory: URL,
        runningBundleURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let running = standardized(runningBundleURL)
        return
            names
            .filter(isLeftoverCopyName)
            .map { standardized(directory.appendingPathComponent($0)) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { $0 != running }
            .sorted { $0.path < $1.path }
    }

    static func loginItemDecision(
        desired: Bool,
        status: MenuLoginItemStatus,
        preferredInstall: Bool = true
    ) -> MenuLoginItemDecision {
        if desired && !preferredInstall && (status == .notRegistered || status == .unknown) {
            return MenuLoginItemDecision(
                action: .none,
                toggleOn: true,
                message: "Launch at login will bind after this copy is in /Applications"
            )
        }
        switch (desired, status) {
        case (true, .enabled):
            return MenuLoginItemDecision(
                action: .none,
                toggleOn: true,
                message: "Menu-bar app launches at login"
            )
        case (true, .requiresApproval):
            return MenuLoginItemDecision(
                action: .requestApproval,
                toggleOn: true,
                message: "Launch at login requires approval in Login Items"
            )
        case (true, .notRegistered):
            return MenuLoginItemDecision(
                action: .rebindCurrentBundle,
                toggleOn: true,
                message: "Launch at login will rebind to this copy"
            )
        case (true, .unknown):
            return MenuLoginItemDecision(
                action: .rebindCurrentBundle,
                toggleOn: true,
                message: "Menu-bar launch-at-login state is unknown; rebinding this copy"
            )
        case (false, .enabled):
            return MenuLoginItemDecision(
                action: .unbindCurrentBundle,
                toggleOn: false,
                message: "Menu-bar launch at login is off"
            )
        case (false, _):
            return MenuLoginItemDecision(
                action: .none,
                toggleOn: false,
                message: "Menu-bar launch at login is off"
            )
        }
    }

    static func coalesceLoginItemStatus(
        observed: MenuLoginItemStatus,
        desired: Bool,
        registeredThisSession: Bool
    ) -> MenuLoginItemStatus {
        if observed == .enabled || observed == .requiresApproval { return observed }
        if desired && registeredThisSession && (observed == .notRegistered || observed == .unknown) {
            return .enabled
        }
        return observed
    }

    static func resolvedStatusAfterMutation(
        mutation: LoginItemMutation,
        observed: MenuLoginItemStatus,
        elapsed: TimeInterval,
        timeout: TimeInterval = 6
    ) -> LoginItemMutationResolution {
        switch mutation {
        case .register:
            if observed == .enabled || observed == .requiresApproval {
                return LoginItemMutationResolution(status: observed, keepWaiting: false)
            }
            return LoginItemMutationResolution(
                status: .enabled,
                keepWaiting: elapsed < timeout
            )
        case .unregister:
            if observed == .notRegistered {
                return LoginItemMutationResolution(status: observed, keepWaiting: false)
            }
            return LoginItemMutationResolution(
                status: .notRegistered,
                keepWaiting: elapsed < timeout
            )
        }
    }

    static func issues(
        preferredInstall: Bool,
        leftoverCount: Int,
        loginItem: MenuLoginItemDecision,
        agentRequiresApproval: Bool,
        agentUnreachableAfterRepair: Bool
    ) -> [RepairIssue] {
        var issues: [RepairIssue] = []
        if !preferredInstall { issues.append(.runningOutsideApplications) }
        if leftoverCount > 0 { issues.append(.leftoverUserSpaceCopies(leftoverCount)) }
        switch loginItem.action {
        case .requestApproval:
            issues.append(.loginItemNeedsApproval)
        case .rebindCurrentBundle:
            issues.append(.loginItemNeedsRebind)
        case .none, .unbindCurrentBundle:
            break
        }
        if agentRequiresApproval { issues.append(.agentNeedsApproval) }
        if agentUnreachableAfterRepair { issues.append(.agentUnreachable) }
        return issues
    }

    static func shouldPresentRepairCard(
        setupDoctorVisible: Bool,
        issues: [RepairIssue]
    ) -> Bool {
        if issues.isEmpty { return false }
        if !setupDoctorVisible { return true }
        return issues.contains { issue in
            switch issue {
            case .runningOutsideApplications, .leftoverUserSpaceCopies:
                return true
            case .loginItemNeedsApproval, .loginItemNeedsRebind, .agentNeedsApproval, .agentUnreachable:
                return false
            }
        }
    }
}
