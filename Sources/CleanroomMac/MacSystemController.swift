import CleanroomCore
import Foundation

public actor MacSystemController: CleanroomSystemControlling {
    public static let legacyAgentLabel = "com.rex.roblox-focus-cleanroom"

    private let commands: any CommandRunning
    private let applications: any ApplicationManaging
    private let userIdentifier: uid_t

    public init(
        commands: any CommandRunning,
        applications: any ApplicationManaging,
        userIdentifier: uid_t = getuid()
    ) {
        self.commands = commands
        self.applications = applications
        self.userIdentifier = userIdentifier
    }

    @MainActor
    public static func live() -> MacSystemController {
        MacSystemController(
            commands: LocalCommandRunner(),
            applications: WorkspaceApplicationManager()
        )
    }

    public func probeTrigger() async -> TriggerProbe {
        let probe = await applications.probe(bundleIdentifier: CleanroomProfile.robloxBundleIdentifier)
        switch probe.state {
        case .running:
            guard let processIdentifier = probe.processIdentifier else {
                return TriggerProbe(state: .unknown, detail: "Roblox has no process identifier.")
            }
            return TriggerProbe(
                state: .running,
                process: TriggerProcess(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: CleanroomProfile.robloxBundleIdentifier,
                    executableURL: probe.executableURL
                )
            )
        case .stopped:
            return TriggerProbe(state: .stopped)
        case .unknown:
            return TriggerProbe(state: .unknown, detail: probe.detail)
        }
    }

    public func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot {
        var serviceLabels: [String] = []
        var bundleIdentifiers: [String] = []
        var processNames: [String] = []
        var preferences: [StoredPreference] = []

        for service in profile.services {
            switch await probeService(label: service.label) {
            case .running: serviceLabels.append(service.label)
            case .stopped: break
            case .unknown:
                throw CleanroomError.mutationFailed("Could not inspect service \(service.label).")
            }
        }

        for application in profile.applications {
            let probe = await applications.probe(bundleIdentifier: application.bundleIdentifier)
            switch probe.state {
            case .running: bundleIdentifiers.append(application.bundleIdentifier)
            case .stopped: break
            case .unknown:
                throw CleanroomError.mutationFailed("Could not inspect \(application.name).")
            }
        }

        for process in profile.processes {
            switch await probeProcess(executableName: process.executableName) {
            case .running: processNames.append(process.executableName)
            case .stopped: break
            case .unknown:
                throw CleanroomError.mutationFailed("Could not inspect process \(process.executableName).")
            }
        }

        for preference in profile.preferences {
            preferences.append(try await readPreference(preference))
        }

        return SystemSnapshot(
            activeServiceLabels: serviceLabels,
            activeApplicationBundleIdentifiers: bundleIdentifiers,
            activeProcessNames: processNames,
            preferences: preferences
        )
    }

    public func apply(profile: CleanroomProfile) async -> [ActionResult] {
        if await probeService(label: Self.legacyAgentLabel) == .running {
            return [
                ActionResult(
                    action: "safety check",
                    target: Self.legacyAgentLabel,
                    outcome: .failed,
                    detail: "The legacy watcher is loaded. Run the guided migration before entering Cleanroom."
                )
            ]
        }

        var results: [ActionResult] = []
        for preference in profile.preferences {
            results.append(await writePreference(preference))
        }
        results.append(contentsOf: await synchronizeProcesses(for: profile.preferences))

        let componentResults = await withTaskGroup(of: ActionResult.self) { group in
            for service in profile.services {
                group.addTask { await self.stopService(service) }
            }
            for application in profile.applications {
                group.addTask {
                    await self.applications.stop(
                        bundleIdentifier: application.bundleIdentifier,
                        displayName: application.name
                    )
                }
            }
            for process in profile.processes {
                group.addTask { await self.stopProcess(process) }
            }

            var collected: [ActionResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        results.append(contentsOf: componentResults.sorted(by: resultSort))
        return results
    }

    public func verifyApplied(profile: CleanroomProfile) async -> [ActionResult] {
        var results: [ActionResult] = []

        if await probeService(label: Self.legacyAgentLabel) == .running {
            results.append(
                ActionResult(
                    action: "verify legacy watcher",
                    target: Self.legacyAgentLabel,
                    outcome: .failed,
                    detail: "Legacy watcher remains loaded."
                ))
        }

        for preference in profile.preferences {
            results.append(await verifyPreference(preference))
        }
        for service in profile.services {
            results.append(
                probeResult(
                    action: "verify service stopped",
                    target: service.name,
                    actual: await probeService(label: service.label),
                    expected: .stopped
                ))
        }
        for application in profile.applications {
            results.append(
                probeResult(
                    action: "verify application stopped",
                    target: application.name,
                    actual: await applications.probe(bundleIdentifier: application.bundleIdentifier).state,
                    expected: .stopped
                ))
        }
        for process in profile.processes {
            results.append(
                probeResult(
                    action: "verify process stopped",
                    target: process.name,
                    actual: await probeProcess(executableName: process.executableName),
                    expected: .stopped
                ))
        }
        return results
    }

    public func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) async -> [ActionResult] {
        var results = validate(snapshot: snapshot, profile: profile)
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return results
        }

        for stored in snapshot.preferences {
            guard
                profile.preferences.contains(where: {
                    $0.domain == stored.domain && $0.key == stored.key && $0.kind == stored.kind
                })
            else { continue }
            results.append(await restorePreference(stored))
        }
        results.append(contentsOf: await synchronizeProcesses(for: profile.preferences))

        let componentResults = await withTaskGroup(of: ActionResult.self) { group in
            for label in snapshot.activeServiceLabels {
                guard let service = profile.services.first(where: { $0.label == label }) else { continue }
                group.addTask { await self.restoreService(service) }
            }
            for bundleIdentifier in snapshot.activeApplicationBundleIdentifiers {
                guard
                    let application = profile.applications.first(where: {
                        $0.bundleIdentifier == bundleIdentifier && $0.restoreWhenPreviouslyRunning
                    })
                else { continue }
                group.addTask {
                    await self.applications.start(
                        bundleIdentifier: application.bundleIdentifier,
                        displayName: application.name
                    )
                }
            }
            for executableName in snapshot.activeProcessNames {
                guard
                    let process = profile.processes.first(where: {
                        $0.executableName == executableName
                    })
                else { continue }
                group.addTask { await self.restoreProcess(process) }
            }

            var collected: [ActionResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        results.append(contentsOf: componentResults.sorted(by: resultSort))

        for stored in snapshot.preferences {
            guard
                profile.preferences.contains(where: {
                    $0.domain == stored.domain && $0.key == stored.key && $0.kind == stored.kind
                })
            else { continue }
            results.append(await verifyRestoredPreference(stored))
        }
        return results
    }

    public func preflight(profile: CleanroomProfile) async -> PreflightReport {
        var findings: [PreflightFinding] = []

        if await probeService(label: Self.legacyAgentLabel) == .running {
            findings.append(
                PreflightFinding(
                    id: "legacy-agent",
                    severity: .critical,
                    category: "Ownership",
                    summary: "Legacy Roblox watcher is still loaded",
                    detail: "Two state owners could overwrite each other's recovery data.",
                    remediation: "Run cleanroomctl migrate-legacy while Roblox is closed."
                ))
        }

        for application in profile.applications {
            if await applications.probe(bundleIdentifier: application.bundleIdentifier).state == .running {
                findings.append(
                    PreflightFinding(
                        id: "managed-app-\(application.bundleIdentifier)",
                        severity: .information,
                        category: "Managed app",
                        summary: "\(application.name) is active",
                        detail: "Cleanroom will stop it for the session and restore it afterward."
                    ))
            }
        }

        findings.append(contentsOf: await processLoadFindings(profile: profile))
        findings.append(contentsOf: await timeMachineFindings())
        findings.append(contentsOf: await inputFindings())
        findings.append(contentsOf: await networkFindings())
        findings.append(contentsOf: await powerAndThermalFindings())

        if findings.isEmpty {
            findings.append(
                PreflightFinding(
                    id: "ready",
                    severity: .information,
                    category: "Readiness",
                    summary: "No competitive blockers detected",
                    detail: "The automated checks found no active interference."
                ))
        }
        return PreflightReport(findings: findings)
    }

    public func migrateLegacy() async -> TransitionReport {
        let trigger = await probeTrigger()
        guard trigger.state == .stopped else {
            let detail =
                trigger.state == .running
                ? "Close Roblox before migrating the legacy watcher."
                : "Roblox state is unknown; migration was refused."
            return TransitionReport(phase: .degraded, message: detail)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let utilityURL = home.appendingPathComponent("bin/roblox-focus-cleanroom")
        let propertyListURL = home.appendingPathComponent(
            "Library/LaunchAgents/\(Self.legacyAgentLabel).plist"
        )
        let serviceState = await probeService(label: Self.legacyAgentLabel)
        guard serviceState != .unknown else {
            return TransitionReport(
                phase: .degraded,
                message: "Legacy LaunchAgent state could not be determined."
            )
        }
        if serviceState == .stopped,
            !FileManager.default.fileExists(atPath: propertyListURL.path)
        {
            return TransitionReport(
                phase: .idle,
                message: "No legacy watcher is installed.",
                results: [
                    ActionResult(
                        action: "migrate legacy watcher",
                        target: Self.legacyAgentLabel,
                        outcome: .skipped,
                        detail: "Already absent."
                    )
                ]
            )
        }

        guard FileManager.default.isExecutableFile(atPath: utilityURL.path) else {
            return TransitionReport(
                phase: .degraded,
                message: "Legacy utility is missing; automatic recovery-aware migration is unavailable."
            )
        }
        let status = await commands.run(utilityURL.path, arguments: ["status"], timeout: 10)
        guard status.succeeded else {
            return TransitionReport(phase: .degraded, message: "Legacy status check failed: \(commandFailure(status))")
        }
        if status.standardOutput.contains("Cleanroom active: yes") {
            let restore = await commands.run(utilityURL.path, arguments: ["restore"], timeout: 60)
            guard restore.succeeded else {
                return TransitionReport(
                    phase: .degraded, message: "Legacy restoration failed: \(commandFailure(restore))")
            }
        }

        var uninstall = await commands.run(utilityURL.path, arguments: ["uninstall-agent"], timeout: 15)
        if !uninstall.succeeded {
            uninstall = await commands.run(
                "/bin/launchctl",
                arguments: ["bootout", "gui/\(userIdentifier)/\(Self.legacyAgentLabel)"],
                timeout: 8
            )
        }
        guard await probeService(label: Self.legacyAgentLabel) == .stopped else {
            return TransitionReport(
                phase: .degraded, message: "Legacy watcher could not be unloaded: \(commandFailure(uninstall))")
        }
        if FileManager.default.fileExists(atPath: propertyListURL.path) {
            do {
                try FileManager.default.removeItem(at: propertyListURL)
            } catch {
                return TransitionReport(
                    phase: .degraded,
                    message:
                        "Legacy watcher is stopped, but its plist could not be removed: \(error.localizedDescription)")
            }
        }
        return TransitionReport(
            phase: .idle,
            message: "Legacy watcher restored, unloaded, and removed.",
            results: [
                ActionResult(
                    action: "migrate legacy watcher",
                    target: Self.legacyAgentLabel,
                    outcome: .succeeded,
                    detail: "The Swift agent can safely take ownership."
                )
            ]
        )
    }

    private func validate(snapshot: SystemSnapshot, profile: CleanroomProfile) -> [ActionResult] {
        let allowedServices = Set(profile.services.map(\.label))
        let allowedApplications = Set(profile.applications.map(\.bundleIdentifier))
        let allowedProcesses = Set(profile.processes.map(\.executableName))
        let allowedPreferences = Set(profile.preferences.map { "\($0.domain)\u{0}\($0.key)\u{0}\($0.kind.rawValue)" })
        var invalid: [String] = []
        invalid += snapshot.activeServiceLabels.filter { !allowedServices.contains($0) }
        invalid += snapshot.activeApplicationBundleIdentifiers.filter { !allowedApplications.contains($0) }
        invalid += snapshot.activeProcessNames.filter { !allowedProcesses.contains($0) }
        invalid += snapshot.preferences.compactMap {
            let key = "\($0.domain)\u{0}\($0.key)\u{0}\($0.kind.rawValue)"
            return allowedPreferences.contains(key) ? nil : "\($0.domain):\($0.key)"
        }
        guard !invalid.isEmpty else { return [] }
        return [
            ActionResult(
                action: "validate recovery snapshot",
                target: "recovery.json",
                outcome: .failed,
                detail: "Snapshot contains unmanaged entries: \(invalid.joined(separator: ", "))."
            )
        ]
    }

    private func readPreference(_ preference: PreferenceAction) async throws -> StoredPreference {
        let result = await commands.run(
            "/usr/bin/defaults",
            arguments: ["read", preference.domain, preference.key],
            timeout: 3
        )
        if result.succeeded {
            return StoredPreference(
                domain: preference.domain,
                key: preference.key,
                kind: preference.kind,
                wasPresent: true,
                value: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let detail = "\(result.standardOutput)\n\(result.standardError)".lowercased()
        if !result.timedOut,
            result.launchError == nil,
            detail.contains("does not exist") || detail.contains("could not find")
        {
            return StoredPreference(
                domain: preference.domain,
                key: preference.key,
                kind: preference.kind,
                wasPresent: false,
                value: nil
            )
        }
        throw CleanroomError.mutationFailed(
            "Could not read \(preference.domain):\(preference.key): \(commandFailure(result))"
        )
    }

    private func writePreference(_ preference: PreferenceAction) async -> ActionResult {
        let result = await commands.run(
            "/usr/bin/defaults",
            arguments: [
                "write", preference.domain, preference.key,
                defaultsFlag(preference.kind), preference.activeValue,
            ],
            timeout: 3
        )
        return ActionResult(
            action: "apply preference",
            target: "\(preference.domain):\(preference.key)",
            outcome: result.succeeded ? .succeeded : .failed,
            detail: result.succeeded ? "Set to \(preference.activeValue)." : commandFailure(result)
        )
    }

    private func restorePreference(_ stored: StoredPreference) async -> ActionResult {
        let target = "\(stored.domain):\(stored.key)"
        let arguments: [String]
        if stored.wasPresent, let value = stored.value {
            arguments = [
                "write", stored.domain, stored.key, defaultsFlag(stored.kind),
                defaultsWriteValue(value, kind: stored.kind),
            ]
        } else {
            arguments = ["delete", stored.domain, stored.key]
        }
        let result = await commands.run("/usr/bin/defaults", arguments: arguments, timeout: 3)
        var deletionAlreadySatisfied = false
        if !stored.wasPresent, !result.succeeded {
            let action = PreferenceAction(
                domain: stored.domain,
                key: stored.key,
                kind: stored.kind,
                activeValue: ""
            )
            if let actual = try? await readPreference(action) {
                deletionAlreadySatisfied = !actual.wasPresent
            }
        }
        return ActionResult(
            action: "restore preference",
            target: target,
            outcome: result.succeeded || deletionAlreadySatisfied ? .succeeded : .failed,
            detail: result.succeeded || deletionAlreadySatisfied
                ? (stored.wasPresent ? "Restored saved value." : "Restored key absence.")
                : commandFailure(result)
        )
    }

    private func verifyPreference(_ preference: PreferenceAction) async -> ActionResult {
        do {
            let stored = try await readPreference(preference)
            let matches =
                stored.wasPresent
                && valuesMatch(stored.value, preference.activeValue, kind: preference.kind)
            return ActionResult(
                action: "verify preference",
                target: "\(preference.domain):\(preference.key)",
                outcome: matches ? .succeeded : .failed,
                detail: matches
                    ? "Active value verified."
                    : "Expected \(preference.activeValue), found \(stored.value ?? "absent")."
            )
        } catch {
            return ActionResult(
                action: "verify preference",
                target: "\(preference.domain):\(preference.key)",
                outcome: .unknown,
                detail: error.localizedDescription
            )
        }
    }

    private func verifyRestoredPreference(_ stored: StoredPreference) async -> ActionResult {
        let action = PreferenceAction(
            domain: stored.domain,
            key: stored.key,
            kind: stored.kind,
            activeValue: stored.value ?? ""
        )
        do {
            let actual = try await readPreference(action)
            let matches =
                actual.wasPresent == stored.wasPresent
                && (!stored.wasPresent || valuesMatch(actual.value, stored.value, kind: stored.kind))
            return ActionResult(
                action: "verify restored preference",
                target: "\(stored.domain):\(stored.key)",
                outcome: matches ? .succeeded : .failed,
                detail: matches ? "Saved state verified." : "Restored value does not match the recovery journal."
            )
        } catch {
            return ActionResult(
                action: "verify restored preference",
                target: "\(stored.domain):\(stored.key)",
                outcome: .unknown,
                detail: error.localizedDescription
            )
        }
    }

    private func synchronizeProcesses(for preferences: [PreferenceAction]) async -> [ActionResult] {
        let processNames = Set(preferences.compactMap(\.synchronizeProcess)).sorted()
        var results: [ActionResult] = []
        for name in processNames {
            let result = await commands.run("/usr/bin/killall", arguments: [name], timeout: 3)
            results.append(
                ActionResult(
                    action: "synchronize preferences",
                    target: name,
                    outcome: result.succeeded ? .succeeded : .warning,
                    detail: result.succeeded
                        ? "Requested a clean relaunch."
                        : "Process was not running or did not relaunch: \(commandFailure(result))"
                ))
        }
        return results
    }

    private func probeService(label: String) async -> ProbeState {
        let result = await commands.run(
            "/bin/launchctl",
            arguments: ["print", "gui/\(userIdentifier)/\(label)"],
            timeout: 3
        )
        if result.succeeded { return .running }
        if result.timedOut || result.launchError != nil { return .unknown }
        let detail = "\(result.standardOutput)\n\(result.standardError)".lowercased()
        if detail.contains("could not find service")
            || detail.contains("service not found")
            || detail.contains("no such process")
        {
            return .stopped
        }
        return result.exitCode == 113 ? .stopped : .unknown
    }

    private func stopService(_ service: ManagedService) async -> ActionResult {
        let state = await probeService(label: service.label)
        if state == .stopped {
            return ActionResult(
                action: "stop service", target: service.name, outcome: .skipped, detail: "Was already stopped.")
        }
        if state == .unknown {
            return ActionResult(
                action: "stop service", target: service.name, outcome: .unknown,
                detail: "Service state could not be determined.")
        }
        let result = await commands.run(
            "/bin/launchctl",
            arguments: ["bootout", "gui/\(userIdentifier)/\(service.label)"],
            timeout: 5
        )
        let postcondition = await probeService(label: service.label)
        let stopped = result.succeeded && postcondition == .stopped
        return ActionResult(
            action: "stop service",
            target: service.name,
            outcome: stopped ? .succeeded : .failed,
            detail: stopped ? "Unloaded for this session." : commandFailure(result)
        )
    }

    private func restoreService(_ service: ManagedService) async -> ActionResult {
        let state = await probeService(label: service.label)
        if state == .running {
            return ActionResult(
                action: "restore service", target: service.name, outcome: .skipped, detail: "Already running.")
        }
        if state == .unknown {
            return ActionResult(
                action: "restore service", target: service.name, outcome: .unknown,
                detail: "Service state could not be determined.")
        }
        guard FileManager.default.fileExists(atPath: service.propertyListURL.path) else {
            return ActionResult(
                action: "restore service", target: service.name, outcome: .failed,
                detail: "LaunchAgent plist is missing at \(service.propertyListURL.path).")
        }
        let result = await commands.run(
            "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(userIdentifier)", service.propertyListURL.path],
            timeout: 5
        )
        let postcondition = await waitForService(service.label, expected: .running, timeout: 4)
        let running = result.succeeded && postcondition
        return ActionResult(
            action: "restore service",
            target: service.name,
            outcome: running ? .succeeded : .failed,
            detail: running ? "Reloaded from its saved LaunchAgent." : commandFailure(result)
        )
    }

    private func waitForService(_ label: String, expected: ProbeState, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeService(label: label) == expected { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await probeService(label: label) == expected
    }

    private func probeProcess(executableName: String) async -> ProbeState {
        let result = await commands.run(
            "/usr/bin/pgrep",
            arguments: ["-x", executableName],
            timeout: 3
        )
        if result.succeeded { return .running }
        if !result.timedOut, result.launchError == nil, result.exitCode == 1 { return .stopped }
        return .unknown
    }

    private func stopProcess(_ process: ManagedProcess) async -> ActionResult {
        let state = await probeProcess(executableName: process.executableName)
        if state == .stopped {
            return ActionResult(
                action: "stop process", target: process.name, outcome: .skipped, detail: "Was already stopped.")
        }
        if state == .unknown {
            return ActionResult(
                action: "stop process", target: process.name, outcome: .unknown,
                detail: "Process state could not be determined.")
        }
        let termination = await commands.run(
            "/usr/bin/pkill",
            arguments: ["-TERM", "-x", process.executableName],
            timeout: 3
        )
        if termination.succeeded {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if await probeProcess(executableName: process.executableName) == .stopped {
                    return ActionResult(
                        action: "stop process", target: process.name, outcome: .succeeded,
                        detail: "Terminated gracefully.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let forced = await commands.run(
            "/usr/bin/pkill",
            arguments: ["-KILL", "-x", process.executableName],
            timeout: 3
        )
        let postcondition = await probeProcess(executableName: process.executableName)
        let stopped = forced.succeeded && postcondition == .stopped
        return ActionResult(
            action: "stop process",
            target: process.name,
            outcome: stopped ? .succeeded : .failed,
            detail: stopped ? "Force-terminated after grace period." : commandFailure(forced)
        )
    }

    private func restoreProcess(_ process: ManagedProcess) async -> ActionResult {
        if await probeProcess(executableName: process.executableName) == .running {
            return ActionResult(
                action: "restore process", target: process.name, outcome: .skipped, detail: "Already running.")
        }
        guard let executable = process.relaunchCommand.first else {
            return ActionResult(
                action: "restore process", target: process.name, outcome: .failed, detail: "Relaunch command is empty.")
        }
        let started = await commands.start(executable, arguments: Array(process.relaunchCommand.dropFirst()))
        guard started.succeeded else {
            return ActionResult(
                action: "restore process", target: process.name, outcome: .failed, detail: commandFailure(started))
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if await probeProcess(executableName: process.executableName) == .running {
                return ActionResult(
                    action: "restore process", target: process.name, outcome: .succeeded,
                    detail: "Relaunched saved process.")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return ActionResult(
            action: "restore process", target: process.name, outcome: .failed,
            detail: "Relaunch command ran, but the process did not remain active.")
    }

    private func processLoadFindings(profile: CleanroomProfile) async -> [PreflightFinding] {
        let result = await commands.run(
            "/bin/ps",
            arguments: ["-Ao", "pid=,pcpu=,comm="],
            timeout: 4
        )
        guard result.succeeded else {
            return [
                PreflightFinding(
                    id: "process-scan-unknown",
                    severity: .warning,
                    category: "Performance",
                    summary: "Process load could not be inspected",
                    detail: commandFailure(result),
                    remediation: "Re-run preflight before competitive play."
                )
            ]
        }

        struct Load: Sendable {
            let pid: Int
            let cpu: Double
            let name: String
        }
        let samples = result.standardOutput.split(separator: "\n").compactMap { line -> Load? in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                let pid = Int(fields[0]),
                let cpu = Double(fields[1]),
                pid != Int(getpid())
            else { return nil }
            return Load(pid: pid, cpu: cpu, name: String(fields[2]))
        }

        var findings =
            samples
            .filter { $0.cpu >= profile.processCPUWarningPercent }
            .sorted { $0.cpu > $1.cpu }
            .prefix(8)
            .map { load in
                let critical = load.cpu >= profile.processCPUCriticalPercent
                return PreflightFinding(
                    id: "cpu-\(load.pid)",
                    severity: critical ? .critical : .warning,
                    category: "Performance",
                    summary:
                        "\(URL(fileURLWithPath: load.name).lastPathComponent) is using \(Int(load.cpu.rounded()))% CPU",
                    detail: "PID \(load.pid) may compete with Roblox for CPU or graphics scheduling.",
                    remediation: "Close or pause it if this load persists."
                )
            }

        let residentGroups: [(String, [String], PreflightSeverity, String, String, String)] = [
            (
                "virtualization-active",
                ["orbstack", "multipass", "qemu", "virtualbox", "vmware", "docker desktop"],
                .warning,
                "Virtualization workload is resident",
                "VM networking, storage, and CPU activity can create latency or frame-time spikes.",
                "Stop idle VMs and containers before competitive play."
            ),
            (
                "capture-tool-active",
                ["screenflow", "camtasia", "screen recording", "replaykit"],
                .warning,
                "Screen capture software is resident",
                "Capture and encoding can contend for WindowServer, GPU, and audio resources.",
                "Stop capture software unless recording is intentional."
            ),
            (
                "network-filter-active",
                ["little snitch", "littlesnitch", "at.obdev.littlesnitch"],
                .information,
                "Little Snitch services are resident",
                "The network and endpoint filters remain operator-controlled; unusual filter load can affect latency.",
                "Check its rules and load if Roblox networking feels inconsistent."
            ),
            (
                "sync-client-active",
                ["dropbox", "google drive", "onedrive", "bird"],
                .information,
                "A file-sync client is resident",
                "Large sync transfers can compete for network or storage bandwidth.",
                "Pause large transfers during a competitive session."
            ),
        ]
        let inventory = samples.map { $0.name.lowercased() }
        for group in residentGroups
        where inventory.contains(where: { name in
            group.1.contains(where: name.contains)
        }) {
            findings.append(
                PreflightFinding(
                    id: group.0,
                    severity: group.2,
                    category: "Resident software",
                    summary: group.3,
                    detail: group.4,
                    remediation: group.5
                ))
        }
        return findings
    }

    private func timeMachineFindings() async -> [PreflightFinding] {
        let result = await commands.run("/usr/bin/tmutil", arguments: ["status"], timeout: 4)
        guard result.succeeded else { return [] }
        guard result.standardOutput.contains("Running = 1") else { return [] }
        return [
            PreflightFinding(
                id: "time-machine-running",
                severity: .warning,
                category: "Storage",
                summary: "Time Machine backup is active",
                detail: "Backup I/O can create frame-time spikes.",
                remediation: "Allow the backup to finish or pause it manually."
            )
        ]
    }

    private func inputFindings() async -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        let karabiner = await commands.run(
            "/usr/bin/pgrep",
            arguments: ["-if", "karabiner|VirtualHID"],
            timeout: 3
        )
        if karabiner.succeeded {
            findings.append(
                PreflightFinding(
                    id: "karabiner-active",
                    severity: .warning,
                    category: "Input",
                    summary: "Karabiner input services are active",
                    detail:
                        "Virtual HID services remain operator-controlled and can transform keyboard or pointer events.",
                    remediation: "Verify the active Karabiner profile has no gameplay mappings."
                ))
        } else if karabiner.exitCode != 1 || karabiner.timedOut || karabiner.launchError != nil {
            findings.append(
                PreflightFinding(
                    id: "input-scan-unknown",
                    severity: .warning,
                    category: "Input",
                    summary: "Input-hook process state is unknown",
                    detail: commandFailure(karabiner),
                    remediation: "Re-run preflight before competitive play."
                ))
        }

        let devices = await commands.run(
            "/usr/sbin/ioreg",
            arguments: ["-r", "-c", "IOHIDDevice", "-k", "Transport", "-k", "Product", "-l"],
            timeout: 5
        )
        if devices.succeeded {
            let lower = devices.standardOutput.lowercased()
            if !lower.contains("mouse") && !lower.contains("razer") {
                findings.append(
                    PreflightFinding(
                        id: "external-mouse-missing",
                        severity: .critical,
                        category: "Input",
                        summary: "External mouse was not detected",
                        detail: "The built-in trackpad will be disabled while an external pointing device is present.",
                        remediation: "Connect the gameplay mouse before launching Roblox."
                    ))
            } else {
                findings.append(
                    PreflightFinding(
                        id: "external-pointer-ready",
                        severity: .information,
                        category: "Input",
                        summary: "External gameplay pointer detected",
                        detail: "Cleanroom can gate the built-in trackpad while the external pointer is present."
                    ))
            }
        } else {
            findings.append(
                PreflightFinding(
                    id: "pointer-scan-unknown",
                    severity: .warning,
                    category: "Input",
                    summary: "External pointer state is unknown",
                    detail: commandFailure(devices),
                    remediation: "Confirm the gameplay mouse is connected."
                ))
        }
        return findings
    }

    private func networkFindings() async -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        let vpn = await commands.run("/usr/sbin/scutil", arguments: ["--nc", "list"], timeout: 4)
        if vpn.succeeded, vpn.standardOutput.contains("(Connected)") {
            let connected = vpn.standardOutput.split(separator: "\n")
                .filter { $0.contains("(Connected)") }
                .map(String.init)
                .joined(separator: "; ")
            findings.append(
                PreflightFinding(
                    id: "vpn-connected",
                    severity: .warning,
                    category: "Network",
                    summary: "A system VPN connection is active",
                    detail: connected,
                    remediation: "Confirm Roblox is using the intended route and region."
                ))
        }

        let routes = await commands.run(
            "/usr/sbin/netstat",
            arguments: ["-rn", "-f", "inet"],
            timeout: 4
        )
        if routes.succeeded {
            let defaultRoutes = routes.standardOutput.split(separator: "\n").filter {
                $0.split(whereSeparator: \.isWhitespace).first == "default"
            }
            if defaultRoutes.count > 1 {
                findings.append(
                    PreflightFinding(
                        id: "multiple-default-routes",
                        severity: .warning,
                        category: "Network",
                        summary: "Multiple IPv4 default routes are active",
                        detail: "macOS can change the selected interface as route metrics or link state change.",
                        remediation:
                            "Keep the intended gameplay interface highest priority and avoid switching links mid-match."
                    ))
            }
        }
        return findings
    }

    private func powerAndThermalFindings() async -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            findings.append(
                PreflightFinding(
                    id: "thermal-serious",
                    severity: .critical,
                    category: "Thermals",
                    summary: "Mac thermal pressure is serious",
                    detail: "macOS may reduce CPU or GPU performance.",
                    remediation: "Cool the Mac before competitive play."
                ))
        case .critical:
            findings.append(
                PreflightFinding(
                    id: "thermal-critical",
                    severity: .critical,
                    category: "Thermals",
                    summary: "Mac thermal pressure is critical",
                    detail: "Severe throttling is likely.",
                    remediation: "Stop play and allow the Mac to cool."
                ))
        case .fair:
            findings.append(
                PreflightFinding(
                    id: "thermal-fair",
                    severity: .warning,
                    category: "Thermals",
                    summary: "Mac thermal pressure is elevated",
                    detail: "Sustained performance may decline.",
                    remediation: "Improve airflow and watch frame pacing."
                ))
        case .nominal:
            break
        @unknown default:
            findings.append(
                PreflightFinding(
                    id: "thermal-unknown",
                    severity: .warning,
                    category: "Thermals",
                    summary: "Thermal state is unknown",
                    detail: "macOS returned an unrecognized thermal state."
                ))
        }

        let battery = await commands.run("/usr/bin/pmset", arguments: ["-g", "batt"], timeout: 3)
        if battery.succeeded, battery.standardOutput.contains("Battery Power") {
            findings.append(
                PreflightFinding(
                    id: "battery-power",
                    severity: .warning,
                    category: "Power",
                    summary: "Mac is running on battery power",
                    detail: "Sustained CPU/GPU power limits may be lower than on AC power.",
                    remediation: "Connect the power adapter before competitive play."
                ))
        }
        let power = await commands.run("/usr/bin/pmset", arguments: ["-g", "custom"], timeout: 3)
        let lowPowerModeEnabled = power.standardOutput.split(separator: "\n").contains { line in
            let fields = line.lowercased().split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0] == "lowpowermode" && fields[1] == "1"
        }
        if power.succeeded, lowPowerModeEnabled {
            findings.append(
                PreflightFinding(
                    id: "low-power-mode",
                    severity: .critical,
                    category: "Power",
                    summary: "Low Power Mode is enabled",
                    detail: "Low Power Mode can reduce sustained performance.",
                    remediation: "Disable Low Power Mode before competitive play."
                ))
        }
        return findings
    }

    private func probeResult(
        action: String,
        target: String,
        actual: ProbeState,
        expected: ProbeState
    ) -> ActionResult {
        let outcome: ActionOutcome = actual == .unknown ? .unknown : (actual == expected ? .succeeded : .failed)
        return ActionResult(
            action: action,
            target: target,
            outcome: outcome,
            detail: actual == expected
                ? "Postcondition verified." : "Expected \(expected.rawValue), found \(actual.rawValue)."
        )
    }

    private func defaultsFlag(_ kind: PreferenceKind) -> String {
        switch kind {
        case .boolean: "-bool"
        case .integer: "-int"
        case .string: "-string"
        }
    }

    private func defaultsWriteValue(_ value: String, kind: PreferenceKind) -> String {
        guard kind == .boolean, let boolean = normalizeBoolean(value) else { return value }
        return boolean ? "true" : "false"
    }

    private func valuesMatch(_ lhs: String?, _ rhs: String?, kind: PreferenceKind) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        switch kind {
        case .boolean:
            return normalizeBoolean(lhs) == normalizeBoolean(rhs)
        case .integer:
            return Int(lhs.trimmingCharacters(in: .whitespacesAndNewlines))
                == Int(rhs.trimmingCharacters(in: .whitespacesAndNewlines))
        case .string:
            return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func normalizeBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: nil
        }
    }

    private func commandFailure(_ result: CommandResult) -> String {
        if let launchError = result.launchError { return launchError }
        if result.timedOut { return "Command timed out." }
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Command exited with status \(result.exitCode)." : detail
    }

    private func resultSort(_ lhs: ActionResult, _ rhs: ActionResult) -> Bool {
        if lhs.action != rhs.action { return lhs.action < rhs.action }
        return lhs.target < rhs.target
    }
}
