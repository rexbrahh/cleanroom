import Foundation
import Testing

@testable import CleanroomApp

@Suite("Uninstall policy")
struct UninstallPolicyTests {
    @Test("uninstall always unregisters, boots out, trashes copies, and quits")
    func defaultPlanKeepsLocalData() {
        let preferred = URL(fileURLWithPath: "/Applications/Cleanroom.app")
        let leftover = URL(fileURLWithPath: "/Users/rex/Applications/Cleanroom.app")
        let previous = URL(
            fileURLWithPath:
                "/Users/rex/Library/Application Support/Cleanroom/previous/Cleanroom.previous.1.app"
        )
        let cli = URL(fileURLWithPath: "/Users/rex/bin/cleanroomctl")
        let support = URL(fileURLWithPath: "/Users/rex/Library/Application Support/Cleanroom")
        let legacy = URL(
            fileURLWithPath: "/Users/rex/Library/LaunchAgents/com.rex.cleanroom.agent.plist"
        )

        let plan = UninstallPolicy.plan(
            runningBundleURL: preferred,
            preferredBundleURL: preferred,
            leftoverCopies: [leftover],
            previousBackups: [previous],
            cliLink: cli,
            cliLinkPointsAtCleanroom: true,
            legacyLaunchAgentPlist: legacy,
            supportDirectory: support,
            purgeData: false
        )

        #expect(
            plan.steps == [
                .unregisterAgent,
                .unregisterLoginItem,
                .bootoutAgent,
                .trashBundles,
                .removeExtraFiles,
                .quitApp,
            ]
        )
        #expect(plan.bundlesToTrash == [preferred, leftover, previous])
        #expect(plan.extraRemovals == [cli, legacy])
        #expect(!plan.extraRemovals.contains(support))
    }

    @Test("purge deletes Application Support after copies are gone")
    func purgeAddsSupportRemoval() {
        let preferred = URL(fileURLWithPath: "/Applications/Cleanroom.app")
        let support = URL(fileURLWithPath: "/Users/rex/Library/Application Support/Cleanroom")
        let plan = UninstallPolicy.plan(
            runningBundleURL: preferred,
            preferredBundleURL: preferred,
            leftoverCopies: [],
            previousBackups: [],
            cliLink: nil,
            cliLinkPointsAtCleanroom: false,
            legacyLaunchAgentPlist: nil,
            supportDirectory: support,
            purgeData: true
        )
        #expect(plan.steps.contains(.removeExtraFiles))
        #expect(plan.extraRemovals == [support])
    }

    @Test("running and preferred URLs are not trashed twice")
    func duplicateBundlesAreDeduped() {
        let preferred = URL(fileURLWithPath: "/Applications/Cleanroom.app")
        let plan = UninstallPolicy.plan(
            runningBundleURL: preferred,
            preferredBundleURL: preferred,
            leftoverCopies: [preferred],
            previousBackups: [],
            cliLink: nil,
            cliLinkPointsAtCleanroom: false,
            legacyLaunchAgentPlist: nil,
            supportDirectory: URL(fileURLWithPath: "/tmp/cleanroom-support"),
            purgeData: false
        )
        #expect(plan.bundlesToTrash == [preferred])
    }

    @Test("unrelated ~/bin/cleanroomctl is left alone")
    func foreignCLILinkIsKept() {
        #expect(
            !UninstallPolicy.shouldRemoveCLILink(
                destination: "/opt/homebrew/bin/cleanroomctl"
            )
        )
        #expect(
            UninstallPolicy.shouldRemoveCLILink(
                destination: "/Applications/Cleanroom.app/Contents/Resources/cleanroomctl"
            )
        )
        #expect(
            UninstallPolicy.shouldRemoveCLILink(
                destination: "/Users/rex/Applications/Cleanroom.app/Contents/Resources/cleanroomctl"
            )
        )
    }
}
