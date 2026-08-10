import AppKit
import CleanroomCore
import Foundation

public struct ApplicationInstanceIdentity: Sendable, Equatable {
    public let processIdentifier: Int32
    public let bundleURL: URL?
    public let executableURL: URL?

    public init(processIdentifier: Int32, bundleURL: URL?, executableURL: URL?) {
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }
}

public struct ApplicationProbe: Sendable, Equatable {
    public let state: ProbeState
    public let processIdentifier: Int32?
    public let executableURL: URL?
    public let instances: [ApplicationInstanceIdentity]
    public let detail: String?

    public init(
        state: ProbeState,
        processIdentifier: Int32? = nil,
        executableURL: URL? = nil,
        instances: [ApplicationInstanceIdentity] = [],
        detail: String? = nil
    ) {
        self.state = state
        let resolvedInstances: [ApplicationInstanceIdentity]
        if instances.isEmpty, let processIdentifier {
            resolvedInstances = [
                ApplicationInstanceIdentity(
                    processIdentifier: processIdentifier,
                    bundleURL: nil,
                    executableURL: executableURL
                )
            ]
        } else {
            resolvedInstances = instances
        }
        self.processIdentifier = resolvedInstances.first?.processIdentifier ?? processIdentifier
        self.executableURL = resolvedInstances.first?.executableURL ?? executableURL
        self.instances = resolvedInstances
        self.detail = detail
    }
}

public protocol ApplicationManaging: Sendable {
    func probe(bundleIdentifier: String) async -> ApplicationProbe
    func stop(bundleIdentifier: String, displayName: String) async -> ActionResult
    func start(bundleIdentifier: String, displayName: String) async -> ActionResult
    func start(
        bundleIdentifier: String,
        displayName: String,
        savedState: StoredApplication
    ) async -> ActionResult
}

extension ApplicationManaging {
    public func start(
        bundleIdentifier: String,
        displayName: String,
        savedState: StoredApplication
    ) async -> ActionResult {
        await start(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }
}

@MainActor
public final class WorkspaceApplicationManager: ApplicationManaging {
    public init() {}

    public func probe(bundleIdentifier: String) -> ApplicationProbe {
        guard !bundleIdentifier.isEmpty else {
            return ApplicationProbe(state: .unknown, detail: "Empty bundle identifier.")
        }
        let applications = runningApplications(bundleIdentifier: bundleIdentifier)
        guard let application = applications.first else {
            return ApplicationProbe(state: .stopped)
        }
        return ApplicationProbe(
            state: .running,
            processIdentifier: application.processIdentifier,
            executableURL: application.executableURL,
            instances: applications.map {
                ApplicationInstanceIdentity(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL,
                    executableURL: $0.executableURL
                )
            }
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
        await start(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            savedState: StoredApplication(
                bundleIdentifier: bundleIdentifier,
                processIdentifiers: [],
                bundleURLs: [],
                executableURLs: []
            )
        )
    }

    public func start(
        bundleIdentifier: String,
        displayName: String,
        savedState: StoredApplication
    ) async -> ActionResult {
        let running = runningApplications(bundleIdentifier: bundleIdentifier)
        if !running.isEmpty {
            let expectedPaths = Set(savedState.bundleURLs.map(\.standardizedFileURL.path))
            let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
            if !expectedPaths.isEmpty,
                runningPaths.isEmpty || !runningPaths.isSubset(of: expectedPaths)
            {
                return ActionResult(
                    action: "restore application",
                    target: displayName,
                    outcome: .failed,
                    detail:
                        "A different copy is running; expected one of: \(expectedPaths.sorted().joined(separator: ", "))."
                )
            }
            let runningPIDs = Set(running.map(\.processIdentifier))
            let originalPIDs = Set(savedState.processIdentifiers)
            let detail =
                runningPIDs.isDisjoint(with: originalPIDs)
                ? "A matching application instance was independently relaunched as PID \(runningPIDs.sorted())."
                : "The original recorded application instance remains running as PID \(runningPIDs.sorted())."
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: savedState.processIdentifiers.isEmpty ? .skipped : .warning,
                detail: savedState.processIdentifiers.isEmpty
                    ? "Already running; legacy journal has no PID provenance." : detail
            )
        }
        let savedBundleURL = savedState.bundleURLs.first
        let applicationURL =
            savedBundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        guard let applicationURL else {
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: .failed,
                detail: "Application bundle could not be located."
            )
        }
        if savedBundleURL != nil, !FileManager.default.fileExists(atPath: applicationURL.path) {
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: .failed,
                detail: "The saved application bundle is missing at \(applicationURL.path)."
            )
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let launched = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            let running = await waitUntilRunning(bundleIdentifier: bundleIdentifier, timeout: 4)
            return ActionResult(
                action: "restore application",
                target: displayName,
                outcome: running ? .succeeded : .failed,
                detail: running
                    ? "Relaunched saved bundle as PID \(launched.processIdentifier)."
                    : "Launch returned, but the app did not remain running."
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
