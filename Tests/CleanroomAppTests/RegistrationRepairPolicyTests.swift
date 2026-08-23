import Foundation
import Testing

@testable import CleanroomApp

@Suite("Registration repair policy")
struct RegistrationRepairPolicyTests {
    @Test("missing launch-at-login preference defaults on")
    func missingPreferenceDefaultsOn() {
        #expect(RegistrationRepairPolicy.resolvedLaunchAtLoginDesired(stored: nil))
        #expect(RegistrationRepairPolicy.resolvedLaunchAtLoginDesired(stored: true))
        #expect(!RegistrationRepairPolicy.resolvedLaunchAtLoginDesired(stored: false))
    }

    @Test("only the system Applications copy is preferred")
    func preferredInstallIsSystemApplications() {
        #expect(
            RegistrationRepairPolicy.isPreferredInstall(
                bundleURL: URL(fileURLWithPath: "/Applications/Cleanroom.app")
            )
        )
        #expect(
            !RegistrationRepairPolicy.isPreferredInstall(
                bundleURL: URL(fileURLWithPath: "/Users/rex/Applications/Cleanroom.app")
            )
        )
    }

    @Test("leftover scan keeps Cleanroom.app and previous backups, not the running copy")
    func leftoverScanIgnoresRunningCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanroom-leftovers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = directory.appendingPathComponent("Cleanroom.app")
        let previous = directory.appendingPathComponent("Cleanroom.previous.20260822154432.123.app")
        let other = directory.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let leftovers = RegistrationRepairPolicy.leftoverUserSpaceCopies(
            in: directory,
            runningBundleURL: URL(fileURLWithPath: "/Applications/Cleanroom.app")
        )
        #expect(
            leftovers
                == [live, previous].map(RegistrationRepairPolicy.standardized)
                .sorted { $0.path < $1.path }
        )

        let runningFromUserSpace = RegistrationRepairPolicy.leftoverUserSpaceCopies(
            in: directory,
            runningBundleURL: live
        )
        #expect(runningFromUserSpace == [RegistrationRepairPolicy.standardized(previous)])
    }

    @Test("user-space copies do not auto-rebind login items")
    func userSpaceCopyDoesNotAutoRebind() {
        let decision = RegistrationRepairPolicy.loginItemDecision(
            desired: true,
            status: .notRegistered,
            preferredInstall: false
        )
        #expect(decision.action == .none)
        #expect(decision.toggleOn)
        #expect(decision.message.contains("/Applications"))
    }

    @Test("desired login item rebinds when Service Management lost this copy")
    func desiredLoginItemRebindsWhenUnbound() {
        let rebound = RegistrationRepairPolicy.loginItemDecision(
            desired: true,
            status: .notRegistered
        )
        #expect(rebound.action == .rebindCurrentBundle)
        #expect(rebound.toggleOn)
        #expect(rebound.message.contains("rebind"))

        let approved = RegistrationRepairPolicy.loginItemDecision(
            desired: true,
            status: .enabled
        )
        #expect(approved.action == .none)
        #expect(approved.toggleOn)
        #expect(approved.message == "Menu-bar app launches at login")
    }

    @Test("login-item toggle stays on while approval is pending")
    func approvalKeepsToggleOn() {
        let decision = RegistrationRepairPolicy.loginItemDecision(
            desired: true,
            status: .requiresApproval
        )
        #expect(decision.action == .requestApproval)
        #expect(decision.toggleOn)
        #expect(decision.message.contains("approval"))
    }

    @Test("turning launch at login off unbinds a leftover enabled item")
    func undesiredEnabledItemUnbinds() {
        let decision = RegistrationRepairPolicy.loginItemDecision(
            desired: false,
            status: .enabled
        )
        #expect(decision.action == .unbindCurrentBundle)
        #expect(!decision.toggleOn)
        #expect(decision.message == "Menu-bar launch at login is off")
    }

    @Test("repair card stays after first-run setup when leftovers or approval remain")
    func repairCardSurfacesAfterSetup() {
        let leftoverIssues = RegistrationRepairPolicy.issues(
            preferredInstall: true,
            leftoverCount: 2,
            loginItem: RegistrationRepairPolicy.loginItemDecision(
                desired: true,
                status: .enabled
            ),
            agentRequiresApproval: false,
            agentUnreachableAfterRepair: false
        )
        #expect(leftoverIssues == [.leftoverUserSpaceCopies(2)])
        #expect(
            RegistrationRepairPolicy.shouldPresentRepairCard(
                setupDoctorVisible: false,
                issues: leftoverIssues
            )
        )
        #expect(
            RegistrationRepairPolicy.shouldPresentRepairCard(
                setupDoctorVisible: true,
                issues: leftoverIssues
            )
        )

        let approvalIssues = RegistrationRepairPolicy.issues(
            preferredInstall: true,
            leftoverCount: 0,
            loginItem: RegistrationRepairPolicy.loginItemDecision(
                desired: true,
                status: .requiresApproval
            ),
            agentRequiresApproval: true,
            agentUnreachableAfterRepair: false
        )
        #expect(approvalIssues.contains(.loginItemNeedsApproval))
        #expect(approvalIssues.contains(.agentNeedsApproval))
        #expect(
            !RegistrationRepairPolicy.shouldPresentRepairCard(
                setupDoctorVisible: true,
                issues: approvalIssues
            )
        )
        #expect(
            RegistrationRepairPolicy.shouldPresentRepairCard(
                setupDoctorVisible: false,
                issues: approvalIssues
            )
        )
    }

    @Test("agent unreachability after auto-repair is a guided repair issue")
    func agentUnreachableAfterRepairIsGuided() {
        let issues = RegistrationRepairPolicy.issues(
            preferredInstall: true,
            leftoverCount: 0,
            loginItem: RegistrationRepairPolicy.loginItemDecision(
                desired: true,
                status: .enabled
            ),
            agentRequiresApproval: false,
            agentUnreachableAfterRepair: true
        )
        #expect(issues == [.agentUnreachable])
        #expect(
            RegistrationRepairPolicy.shouldPresentRepairCard(
                setupDoctorVisible: false,
                issues: issues
            )
        )
    }
}
