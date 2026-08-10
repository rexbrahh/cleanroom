import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("Per-target mutation policy")
struct TargetPolicyTests {
    @Test("leave, restore order, delay, and warning severity are enforced")
    func policiesDriveExecution() async throws {
        let applications = PolicyApplicationManager()
        let controller = MacSystemController(
            commands: MissingServiceRunner(),
            applications: applications
        )
        let appA = ManagedApplication(name: "A", bundleIdentifier: "com.example.A", executableName: "A")
        let appB = ManagedApplication(name: "B", bundleIdentifier: "com.example.B", executableName: "B")
        let appC = ManagedApplication(name: "C", bundleIdentifier: "com.example.C", executableName: "C")
        let profile = CleanroomProfile(
            identifier: "policy-test",
            name: "Policy test",
            triggerBundleIdentifier: "com.example.Game",
            applications: [appA, appB, appC],
            services: [],
            processes: [],
            preferences: [],
            targetPolicies: [
                TargetPolicy(targetIdentifier: appA.bundleIdentifier, disposition: .leaveRunning),
                TargetPolicy(
                    targetIdentifier: appB.bundleIdentifier,
                    restoreOrder: 20,
                    restoreDelayMilliseconds: 20,
                    failureSeverity: .warning
                ),
                TargetPolicy(targetIdentifier: appC.bundleIdentifier, restoreOrder: 10),
            ]
        )

        let applied = await controller.apply(profile: profile)
        let verified = await controller.verifyApplied(profile: profile)

        #expect(!(await applications.stopped).contains(appA.bundleIdentifier))
        #expect((await applications.stopped).contains(appB.bundleIdentifier))
        #expect((await applications.stopped).contains(appC.bundleIdentifier))
        #expect(applied.contains { $0.action == "leave application" && $0.target == appA.name })
        #expect(!verified.contains(where: { $0.outcome.blocksCompletion }))

        let snapshot = SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [
                appA.bundleIdentifier, appB.bundleIdentifier, appC.bundleIdentifier,
            ],
            activeProcessNames: [],
            preferences: []
        )
        let restored = await controller.restore(snapshot: snapshot, profile: profile)

        #expect(await applications.started == [appC.bundleIdentifier, appB.bundleIdentifier])
        #expect(
            restored.contains {
                $0.target == appB.name && $0.outcome == .warning
                    && $0.detail.contains("Non-blocking by profile policy")
            }
        )
        #expect(!restored.contains(where: { $0.outcome.blocksCompletion }))
    }
}

private actor PolicyApplicationManager: ApplicationManaging {
    private var running: Set<String> = ["com.example.A", "com.example.B", "com.example.C"]
    private(set) var stopped: [String] = []
    private(set) var started: [String] = []

    func probe(bundleIdentifier: String) -> ApplicationProbe {
        ApplicationProbe(state: running.contains(bundleIdentifier) ? .running : .stopped)
    }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        stopped.append(bundleIdentifier)
        running.remove(bundleIdentifier)
        return ActionResult(
            action: "stop application",
            target: displayName,
            outcome: .succeeded,
            detail: "stopped"
        )
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        started.append(bundleIdentifier)
        let fails = bundleIdentifier == "com.example.B"
        if !fails { running.insert(bundleIdentifier) }
        return ActionResult(
            action: "restore application",
            target: displayName,
            outcome: fails ? .failed : .succeeded,
            detail: fails ? "test failure" : "started"
        )
    }
}

private struct MissingServiceRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: 113,
            standardError: "Could not find service"
        )
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }
}
