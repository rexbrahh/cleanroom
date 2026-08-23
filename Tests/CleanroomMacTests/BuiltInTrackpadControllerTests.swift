import CleanroomCore
import Foundation
import Testing

@testable import CleanroomMac

@Suite("Built-in trackpad apply, verify, and restore")
struct BuiltInTrackpadControllerTests {
    @Test("apply seizes when the lid is open and an external pointer is present")
    func applySeizesWhenLidOpenAndPointerPresent() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .present,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: true
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.apply(profile: enabledProfile)

        #expect(results.contains { $0.action == "suppress built-in trackpad" && $0.outcome == .succeeded })
        #expect(await trackpad.suppressCount == 1)
        #expect(await trackpad.restoreCount == 0)
    }

    @Test("apply leaves the trackpad on when the lid is closed")
    func applySkipsWhenLidClosed() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .closed,
            externalPointer: .present,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: true
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.apply(profile: enabledProfile)

        #expect(results.contains { $0.action == "leave built-in trackpad" && $0.outcome == .skipped })
        #expect(await trackpad.suppressCount == 0)
    }

    @Test("apply leaves the trackpad on when no external pointer is present")
    func applySkipsWhenPointerMissing() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .absent,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: true
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.apply(profile: enabledProfile)

        #expect(results.contains { $0.action == "leave built-in trackpad" && $0.outcome == .skipped })
        #expect(await trackpad.suppressCount == 0)
    }

    @Test("apply restores when a seized trackpad should no longer stay suppressed")
    func applyReleasesWhenPointerDisappears() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .absent,
            builtInTrackpadPresent: true,
            currentlySuppressed: true,
            listenEventAccessGranted: true
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.apply(profile: enabledProfile)

        #expect(results.contains { $0.action == "restore built-in trackpad" && $0.outcome == .succeeded })
        #expect(await trackpad.restoreCount == 1)
    }

    @Test("apply warns when Input Monitoring is denied")
    func applyWarnsWhenListenEventDenied() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .present,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: false
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.apply(profile: enabledProfile)

        #expect(
            results.contains {
                $0.action == "suppress built-in trackpad" && $0.outcome == .warning
                    && $0.detail.contains("Input Monitoring")
            }
        )
        #expect(await trackpad.suppressCount == 0)
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("verify fails so drift repair can seize when access is granted")
    func verifyFailsWhenRepairable() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .present,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: true
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.verifyApplied(profile: enabledProfile)

        #expect(results.contains { $0.action == "verify built-in trackpad" && $0.outcome == .failed })
    }

    @Test("verify warns when access is denied instead of looping as failed")
    func verifyWarnsWhenAccessDenied() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .present,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: false
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.verifyApplied(profile: enabledProfile)

        #expect(results.contains { $0.action == "verify built-in trackpad" && $0.outcome == .warning })
        #expect(!results.contains(where: { $0.outcome.blocksCompletion }))
    }

    @Test("restore always releases a held seize")
    func restoreAlwaysReleases() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .closed,
            externalPointer: .absent,
            builtInTrackpadPresent: true,
            currentlySuppressed: true,
            listenEventAccessGranted: false
        )
        let controller = makeController(trackpad: trackpad)

        let results = await controller.restore(
            snapshot: emptySnapshot,
            profile: enabledProfile
        )

        #expect(results.contains { $0.action == "restore built-in trackpad" && $0.outcome == .succeeded })
        #expect(await trackpad.restoreCount == 1)
    }

    @Test("preflight uses the injected pointer and lid observation")
    func preflightUsesInjectedObservation() async {
        let trackpad = FakeBuiltInTrackpadController(
            lid: .open,
            externalPointer: .unknown,
            builtInTrackpadPresent: true,
            listenEventAccessGranted: false
        )
        let controller = MacSystemController(
            commands: QuietPreflightCommandRunner(),
            applications: IdleApplicationManager(),
            trackpad: trackpad
        )

        let report = await controller.preflight(profile: enabledProfile)
        let identifiers = Set(report.findings.map(\.id))

        #expect(identifiers.contains("pointer-scan-unknown"))
        #expect(identifiers.contains("input-monitoring-missing"))
        #expect(identifiers.contains("lid-open"))
        #expect(!identifiers.contains("external-mouse-missing"))
        #expect(!identifiers.contains("external-pointer-ready"))
    }

    private var enabledProfile: CleanroomProfile {
        CleanroomProfile(
            name: "trackpad-test",
            applications: [],
            services: [],
            processes: [],
            preferences: []
        )
    }

    private var emptySnapshot: SystemSnapshot {
        SystemSnapshot(
            activeServiceLabels: [],
            activeApplicationBundleIdentifiers: [],
            activeProcessNames: [],
            preferences: []
        )
    }

    private func makeController(trackpad: FakeBuiltInTrackpadController) -> MacSystemController {
        MacSystemController(
            commands: QuietPreflightCommandRunner(),
            applications: IdleApplicationManager(),
            trackpad: trackpad
        )
    }
}

actor FakeBuiltInTrackpadController: BuiltInTrackpadControlling {
    var lid: LidState
    var externalPointer: DevicePresence
    var builtInTrackpadPresent: Bool
    var currentlySuppressed: Bool
    var listenEventAccessGranted: Bool
    private(set) var suppressCount = 0
    private(set) var restoreCount = 0

    init(
        lid: LidState,
        externalPointer: DevicePresence,
        builtInTrackpadPresent: Bool,
        currentlySuppressed: Bool = false,
        listenEventAccessGranted: Bool
    ) {
        self.lid = lid
        self.externalPointer = externalPointer
        self.builtInTrackpadPresent = builtInTrackpadPresent
        self.currentlySuppressed = currentlySuppressed
        self.listenEventAccessGranted = listenEventAccessGranted
    }

    func observe() -> BuiltInTrackpadObservation {
        BuiltInTrackpadObservation(
            lid: lid,
            externalPointer: externalPointer,
            builtInTrackpadPresent: builtInTrackpadPresent,
            currentlySuppressed: currentlySuppressed,
            listenEventAccessGranted: listenEventAccessGranted
        )
    }

    func suppress() -> ActionResult {
        suppressCount += 1
        currentlySuppressed = true
        return ActionResult(
            action: "suppress built-in trackpad",
            target: "built-in-trackpad",
            outcome: .succeeded,
            detail: "Seized the built-in trackpad."
        )
    }

    func restore() -> ActionResult {
        restoreCount += 1
        currentlySuppressed = false
        return ActionResult(
            action: "restore built-in trackpad",
            target: "built-in-trackpad",
            outcome: .succeeded,
            detail: "Released the built-in trackpad."
        )
    }
}

private actor QuietPreflightCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/bin/launchctl" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 113,
                standardError: "Could not find service"
            )
        }
        if executable == "/usr/bin/pgrep" {
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1)
        }
        if executable == "/bin/ps" {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "1 0.0 launchd"
            )
        }
        return CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }

    func start(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(executable: executable, arguments: arguments, exitCode: 0)
    }
}

private actor IdleApplicationManager: ApplicationManaging {
    func probe(bundleIdentifier: String) -> ApplicationProbe { ApplicationProbe(state: .stopped) }

    func stop(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "stop application", target: displayName, outcome: .skipped, detail: "stopped")
    }

    func start(bundleIdentifier: String, displayName: String) -> ActionResult {
        ActionResult(action: "start application", target: displayName, outcome: .succeeded, detail: "started")
    }
}
