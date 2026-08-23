import Foundation

enum UninstallStep: Equatable, Sendable {
    case unregisterAgent
    case unregisterLoginItem
    case bootoutAgent
    case trashBundles
    case removeExtraFiles
    case quitApp
}

struct UninstallPlan: Equatable, Sendable {
    var steps: [UninstallStep]
    var bundlesToTrash: [URL]
    var extraRemovals: [URL]
}

enum UninstallPolicy {
    static func shouldRemoveCLILink(destination: String?) -> Bool {
        guard let destination else { return false }
        return destination.contains("Cleanroom.app/") && destination.hasSuffix("cleanroomctl")
    }

    static func previousInstallBackups(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return
            names
            .filter { $0.hasPrefix("Cleanroom.previous.") && $0.hasSuffix(".app") }
            .map { RegistrationRepairPolicy.standardized(directory.appendingPathComponent($0)) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    static func plan(
        runningBundleURL: URL,
        preferredBundleURL: URL,
        leftoverCopies: [URL],
        previousBackups: [URL],
        cliLink: URL?,
        cliLinkPointsAtCleanroom: Bool,
        legacyLaunchAgentPlist: URL?,
        supportDirectory: URL,
        purgeData: Bool
    ) -> UninstallPlan {
        var seen = Set<URL>()
        var bundles: [URL] = []
        for url in [runningBundleURL, preferredBundleURL] + leftoverCopies + previousBackups {
            let standardized = RegistrationRepairPolicy.standardized(url)
            guard seen.insert(standardized).inserted else { continue }
            bundles.append(standardized)
        }

        var extra: [URL] = []
        if cliLinkPointsAtCleanroom, let cliLink {
            extra.append(RegistrationRepairPolicy.standardized(cliLink))
        }
        if let legacyLaunchAgentPlist {
            extra.append(RegistrationRepairPolicy.standardized(legacyLaunchAgentPlist))
        }
        if purgeData {
            extra.append(RegistrationRepairPolicy.standardized(supportDirectory))
        }

        var steps: [UninstallStep] = [
            .unregisterAgent,
            .unregisterLoginItem,
            .bootoutAgent,
            .trashBundles,
        ]
        if !extra.isEmpty { steps.append(.removeExtraFiles) }
        steps.append(.quitApp)

        return UninstallPlan(steps: steps, bundlesToTrash: bundles, extraRemovals: extra)
    }
}
