import AppKit
import CleanroomCore
import Foundation

public struct ApplicationProbe: Sendable, Equatable {
    public let state: ProbeState
    public let processIdentifier: Int32?
    public let executableURL: URL?
    public let detail: String?

    public init(
        state: ProbeState,
        processIdentifier: Int32? = nil,
        executableURL: URL? = nil,
        detail: String? = nil
    ) {
        self.state = state
        self.processIdentifier = processIdentifier
        self.executableURL = executableURL
        self.detail = detail
    }
}

public protocol ApplicationManaging: Sendable {
    func probe(bundleIdentifier: String) async -> ApplicationProbe
    func stop(bundleIdentifier: String, displayName: String) async -> ActionResult
    func start(bundleIdentifier: String, displayName: String) async -> ActionResult
}

@MainActor
public final class WorkspaceApplicationManager: ApplicationManaging {
    public init() {}

    public func probe(bundleIdentifier: String) -> ApplicationProbe {
        guard !bundleIdentifier.isEmpty else {
            return ApplicationProbe(state: .unknown, detail: "Empty bundle identifier.")
        }
        guard let application = runningApplications(bundleIdentifier: bundleIdentifier).first else {
            return ApplicationProbe(state: .stopped)
        }
        return ApplicationProbe(
            state: .running,
            processIdentifier: application.processIdentifier,
            executableURL: application.executableURL
        )
    }

    public func stop(bundleIdentifier: String, displayName: String) async -> ActionResult {
        let applications = runningApplications(bundleIdentifier: bundleIdentifier)
        guard !applications.isEmpty else {
            return ActionResult(
                action: "stop application",
                target: displayName,
                outcome: .skipped,
                detail: "Was already stopped."
            )
        }

        for application in applications {
            _ = application.terminate()
        }
        if await waitUntilStopped(bundleIdentifier: bundleIdentifier, timeout: 1.5) {
            return ActionResult(
                action: "stop application",
                target: displayName,
                outcome: .succeeded,
                detail: "Terminated gracefully."
            )
        }

        for application in runningApplications(bundleIdentifier: bundleIdentifier) {
            _ = application.forceTerminate()
        }
        let stopped = await waitUntilStopped(bundleIdentifier: bundleIdentifier, timeout: 1.5)
        return ActionResult(
            action: "stop application",
            target: displayName,
            outcome: stopped ? .succeeded : .failed,
            detail: stopped ? "Force-terminated after grace period." : "Still running after force termination."
        )
    }

    public func start(bundleIdentifier: String, displayName: String) async -> ActionResult {
        if !runningApplications(bundleIdentifier: bundleIdentifier).isEmpty {
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: .skipped,
                detail: "Already running."
            )
        }
        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        else {
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: .failed,
                detail: "Application bundle could not be located."
            )
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            let running = await waitUntilRunning(bundleIdentifier: bundleIdentifier, timeout: 4)
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: running ? .succeeded : .failed,
                detail: running
                    ? "Relaunched in the background." : "Launch returned, but the app did not remain running."
            )
        } catch {
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: .failed,
                detail: error.localizedDescription
            )
        }
    }

    private func runningApplications(bundleIdentifier: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    private func waitUntilStopped(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningApplications(bundleIdentifier: bundleIdentifier).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return runningApplications(bundleIdentifier: bundleIdentifier).isEmpty
    }

    private func waitUntilRunning(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !runningApplications(bundleIdentifier: bundleIdentifier).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !runningApplications(bundleIdentifier: bundleIdentifier).isEmpty
    }
}
