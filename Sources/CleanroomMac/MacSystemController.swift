import CleanroomCore
import Darwin
import Foundation

public actor MacSystemController: CleanroomSystemControlling {
    public static let legacyAgentLabel = "com.rex.roblox-focus-cleanroom"

    private let commands: any CommandRunning
    private let applications: any ApplicationManaging
    private let preferences: any PreferenceReading
    private let trackpad: any BuiltInTrackpadControlling
    private let userIdentifier: uid_t
    private var preflightSuccesses: [String: Date] = [:]

    public init(
        commands: any CommandRunning,
        applications: any ApplicationManaging,
        preferences: any PreferenceReading = CFPreferenceReader(),
        userIdentifier: uid_t = getuid(),
        trackpad: any BuiltInTrackpadControlling = NullBuiltInTrackpadController()
    ) {
        self.commands = commands
        self.applications = applications
        self.preferences = preferences
        self.userIdentifier = userIdentifier
        self.trackpad = trackpad
    }

    @MainActor
    public static func live() -> MacSystemController {
        MacSystemController(
            commands: LocalCommandRunner(),
            applications: WorkspaceApplicationManager(),
            trackpad: IOHIDBuiltInTrackpadController()
        )
    }

    public func probeTrigger() async -> TriggerProbe {
        await probeTrigger(bundleIdentifier: CleanroomProfile.robloxBundleIdentifier)
    }

    public func probeTrigger(bundleIdentifier: String) async -> TriggerProbe {
        let probe = await applications.probe(bundleIdentifier: bundleIdentifier)
        switch probe.state {
        case .running:
            guard let processIdentifier = probe.processIdentifier else {
                return TriggerProbe(state: .unknown, detail: "Roblox has no process identifier.")
            }
            return TriggerProbe(
                state: .running,
                process: TriggerProcess(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    executableURL: probe.executableURL
                )
            )
        case .stopped:
            return TriggerProbe(state: .stopped)
        case .unknown:
            return TriggerProbe(state: .unknown, detail: probe.detail)
        }
    }

    public func launchTrigger(bundleIdentifier: String) async -> ActionResult {
        await applications.start(bundleIdentifier: bundleIdentifier, displayName: "Roblox")
    }

    public func captureSnapshot(for profile: CleanroomProfile) async throws -> SystemSnapshot {
        var serviceLabels: [String] = []
        var bundleIdentifiers: [String] = []
        var processNames: [String] = []
        var preferences: [StoredPreference] = []
        var applicationStates: [StoredApplication] = []
        var processStates: [StoredProcess] = []

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
            case .running:
                bundleIdentifiers.append(application.bundleIdentifier)
                applicationStates.append(
                    StoredApplication(
                        bundleIdentifier: application.bundleIdentifier,
                        processIdentifiers: probe.instances.map(\.processIdentifier),
                        bundleURLs: probe.instances.compactMap(\.bundleURL),
                        executableURLs: probe.instances.compactMap(\.executableURL)
                    )
                )
            case .stopped: break
            case .unknown:
                throw CleanroomError.mutationFailed("Could not inspect \(application.name).")
            }
        }

        for process in profile.processes {
            let probe = await probeProcessIdentity(executableName: process.executableName)
            switch probe.state {
            case .running:
                processNames.append(process.executableName)
                processStates.append(
                    StoredProcess(
                        executableName: process.executableName,
                        processIdentifiers: probe.processIdentifiers,
                        executableURLs: probe.executableURLs
                    )
                )
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
            preferences: preferences,
            applications: applicationStates,
            processes: processStates
        )
    }

    public func apply(profile: CleanroomProfile) async -> [ActionResult] {
        switch await probeService(label: Self.legacyAgentLabel) {
        case .running:
            return [
                ActionResult(
                    action: "safety check",
                    target: Self.legacyAgentLabel,
                    outcome: .failed,
                    detail: "The legacy watcher is loaded. Run the guided migration before entering Cleanroom."
                )
            ]
        case .unknown:
            return [
                ActionResult(
                    action: "safety check",
                    target: Self.legacyAgentLabel,
                    outcome: .unknown,
                    detail: "Legacy watcher ownership could not be determined; no Cleanroom mutation was attempted."
                )
            ]
        case .stopped:
            break
        }

        var results: [ActionResult] = []
        var changedSyncProcesses: [String] = []
        for preference in profile.preferences {
            let outcome = await writePreferenceIfNeeded(preference)
            results.append(outcome.result)
            if outcome.changed, let synchronize = preference.synchronizeProcess {
                changedSyncProcesses.append(synchronize)
            }
        }
        results.append(contentsOf: await synchronizeProcesses(Set(changedSyncProcesses)))
        results.append(await applyBuiltInTrackpad(profile: profile))

        let policyResults =
            profile.services.compactMap { service in
                profile.policy(for: service.label).disposition == .leaveRunning
                    ? ActionResult(
                        action: "leave service",
                        target: service.name,
                        outcome: .skipped,
                        detail: "Profile policy leaves this service unchanged."
                    ) : nil
            }
            + profile.applications.compactMap { application in
                profile.policy(for: application.bundleIdentifier).disposition == .leaveRunning
                    ? ActionResult(
                        action: "leave application",
                        target: application.name,
                        outcome: .skipped,
                        detail: "Profile policy leaves this application unchanged."
                    ) : nil
            }
            + profile.processes.compactMap { process in
                profile.policy(for: process.executableName).disposition == .leaveRunning
                    ? ActionResult(
                        action: "leave process",
                        target: process.name,
                        outcome: .skipped,
                        detail: "Profile policy leaves this process unchanged."
                    ) : nil
            }
        let componentResults = await withTaskGroup(of: ActionResult.self) { group in
            for service in profile.services
            where profile.policy(for: service.label).disposition == .stop {
                group.addTask {
                    await self.applyFailurePolicy(
                        to: await self.stopService(service),
                        targetIdentifier: service.label,
                        profile: profile
                    )
                }
            }
            for application in profile.applications
            where profile.policy(for: application.bundleIdentifier).disposition == .stop {
                group.addTask {
                    await self.applyFailurePolicy(
                        to: await self.applications.stop(
                            bundleIdentifier: application.bundleIdentifier,
                            displayName: application.name
                        ),
                        targetIdentifier: application.bundleIdentifier,
                        profile: profile
                    )
                }
            }
            for process in profile.processes
            where profile.policy(for: process.executableName).disposition == .stop {
                group.addTask {
                    await self.applyFailurePolicy(
                        to: await self.stopProcess(process),
                        targetIdentifier: process.executableName,
                        profile: profile
                    )
                }
            }

            var collected: [ActionResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        results.append(contentsOf: policyResults)
        results.append(contentsOf: componentResults.sorted(by: resultSort))
        return results
    }

    public func verifyApplied(profile: CleanroomProfile) async -> [ActionResult] {
        var results: [ActionResult] = []

        switch await probeService(label: Self.legacyAgentLabel) {
        case .running:
            results.append(
                ActionResult(
                    action: "verify legacy watcher",
                    target: Self.legacyAgentLabel,
                    outcome: .failed,
                    detail: "Legacy watcher remains loaded."
                ))
        case .unknown:
            results.append(
                ActionResult(
                    action: "verify legacy watcher",
                    target: Self.legacyAgentLabel,
                    outcome: .unknown,
                    detail: "Legacy watcher ownership could not be determined."
                ))
        case .stopped:
            break
        }

        for preference in profile.preferences {
            results.append(await verifyPreference(preference))
        }
        results.append(await verifyBuiltInTrackpad(profile: profile))
        for service in profile.services {
            if profile.policy(for: service.label).disposition == .leaveRunning {
                results.append(
                    ActionResult(
                        action: "verify service policy",
                        target: service.name,
                        outcome: .skipped,
                        detail: "Left unchanged by profile policy."
                    )
                )
                continue
            }
            results.append(
                applyFailurePolicy(
                    to: probeResult(
                        action: "verify service stopped",
                        target: service.name,
                        actual: await probeService(label: service.label),
                        expected: .stopped
                    ),
                    targetIdentifier: service.label,
                    profile: profile
                ))
        }
        for application in profile.applications {
            if profile.policy(for: application.bundleIdentifier).disposition == .leaveRunning {
                results.append(
                    ActionResult(
                        action: "verify application policy",
                        target: application.name,
                        outcome: .skipped,
                        detail: "Left unchanged by profile policy."
                    )
                )
                continue
            }
            results.append(
                applyFailurePolicy(
                    to: probeResult(
                        action: "verify application stopped",
                        target: application.name,
                        actual: await applications.probe(bundleIdentifier: application.bundleIdentifier).state,
                        expected: .stopped
                    ),
                    targetIdentifier: application.bundleIdentifier,
                    profile: profile
                ))
        }
        for process in profile.processes {
            if profile.policy(for: process.executableName).disposition == .leaveRunning {
                results.append(
                    ActionResult(
                        action: "verify process policy",
                        target: process.name,
                        outcome: .skipped,
                        detail: "Left unchanged by profile policy."
                    )
                )
                continue
            }
            results.append(
                applyFailurePolicy(
                    to: probeResult(
                        action: "verify process stopped",
                        target: process.name,
                        actual: await probeProcess(executableName: process.executableName),
                        expected: .stopped
                    ),
                    targetIdentifier: process.executableName,
                    profile: profile
                ))
        }
        return results
    }

    public func restore(snapshot: SystemSnapshot, profile: CleanroomProfile) async -> [ActionResult] {
        var results = validate(snapshot: snapshot, profile: profile)
        if results.contains(where: { $0.outcome.blocksCompletion }) {
            return results
        }

        results.append(await restoreBuiltInTrackpad())

        var changedSyncProcesses: [String] = []
        for stored in snapshot.preferences {
            guard
                profile.preferences.contains(where: {
                    $0.domain == stored.domain && $0.key == stored.key && $0.kind == stored.kind
                })
            else { continue }
            let outcome = await restorePreferenceIfNeeded(stored)
            results.append(outcome.result)
            if outcome.changed,
                let synchronize = profile.preferences.first(where: {
                    $0.domain == stored.domain && $0.key == stored.key && $0.kind == stored.kind
                })?.synchronizeProcess
            {
                changedSyncProcesses.append(synchronize)
            }
        }
        let syncResults = await synchronizeProcesses(Set(changedSyncProcesses))
        results.append(contentsOf: syncResults)
        if syncResults.contains(where: { $0.outcome == .succeeded }) {
            // Give cfprefsd and the relaunched processes (e.g. Dock) a moment
            // to settle before postconditions are read back.
            try? await Task.sleep(for: .milliseconds(1500))
        }

        var components: [RestoreComponent] = []
        for label in snapshot.activeServiceLabels {
            guard let service = profile.services.first(where: { $0.label == label }) else { continue }
            components.append(.service(service))
        }
        for bundleIdentifier in snapshot.activeApplicationBundleIdentifiers {
            guard
                let application = profile.applications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier && $0.restoreWhenPreviouslyRunning
                })
            else { continue }
            let savedState =
                snapshot.applications.first(where: {
                    $0.bundleIdentifier == application.bundleIdentifier
                })
                ?? StoredApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifiers: [],
                    bundleURLs: [],
                    executableURLs: []
                )
            components.append(.application(application, savedState))
        }
        for executableName in snapshot.activeProcessNames {
            guard let process = profile.processes.first(where: { $0.executableName == executableName }) else {
                continue
            }
            let savedState =
                snapshot.processes.first(where: { $0.executableName == executableName })
                ?? StoredProcess(executableName: executableName, processIdentifiers: [])
            components.append(.process(process, savedState))
        }
        components.sort {
            let left = profile.policy(for: $0.identifier)
            let right = profile.policy(for: $1.identifier)
            return left.restoreOrder == right.restoreOrder
                ? $0.identifier < $1.identifier : left.restoreOrder < right.restoreOrder
        }
        for component in components {
            let policy = profile.policy(for: component.identifier)
            guard policy.disposition == .stop else {
                results.append(
                    ActionResult(
                        action: "restore policy",
                        target: component.displayName,
                        outcome: .skipped,
                        detail: "Target was left unchanged, so no restoration was needed."
                    )
                )
                continue
            }
            if policy.restoreDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(policy.restoreDelayMilliseconds))
            }
            let result: ActionResult
            switch component {
            case .service(let service):
                result = await restoreService(service)
            case .application(let application, let savedState):
                result = await applications.start(
                    bundleIdentifier: application.bundleIdentifier,
                    displayName: application.name,
                    savedState: savedState
                )
            case .process(let process, let savedState):
                result = await restoreProcess(process, savedState: savedState)
            }
            results.append(
                applyFailurePolicy(
                    to: result,
                    targetIdentifier: component.identifier,
                    profile: profile
                )
            )
        }

        results.append(contentsOf: await verifyRestoredComponents(snapshot: snapshot, profile: profile))

        var verification: [(stored: StoredPreference, result: ActionResult)] = []
        for stored in snapshot.preferences {
            guard
                profile.preferences.contains(where: {
                    $0.domain == stored.domain && $0.key == stored.key && $0.kind == stored.kind
                })
            else { continue }
            verification.append((stored, await verifyRestoredPreference(stored)))
        }
        if verification.contains(where: { $0.result.outcome.blocksCompletion }) {
            // Verification can race cfprefsd right after a synchronize; retry
            // each failing readback once before declaring the restore failed.
            try? await Task.sleep(for: .seconds(1))
            for index in verification.indices where verification[index].result.outcome.blocksCompletion {
                verification[index].result = await verifyRestoredPreference(verification[index].stored)
            }
        }
        results.append(contentsOf: verification.map(\.result))
        return results
    }

    private func verifyRestoredComponents(
        snapshot: SystemSnapshot,
        profile: CleanroomProfile
    ) async -> [ActionResult] {
        var results: [ActionResult] = []
        for label in snapshot.activeServiceLabels.sorted() {
            guard let service = profile.services.first(where: { $0.label == label }) else { continue }
            guard profile.policy(for: label).disposition == .stop else { continue }
            results.append(
                applyFailurePolicy(
                    to: probeResult(
                        action: "verify restored service",
                        target: service.name,
                        actual: await probeService(label: label),
                        expected: .running
                    ),
                    targetIdentifier: label,
                    profile: profile
                )
            )
        }
        for bundleIdentifier in snapshot.activeApplicationBundleIdentifiers.sorted() {
            guard
                let application = profile.applications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier && $0.restoreWhenPreviouslyRunning
                })
            else { continue }
            guard profile.policy(for: bundleIdentifier).disposition == .stop else { continue }
            results.append(
                applyFailurePolicy(
                    to: probeResult(
                        action: "verify restored application",
                        target: application.name,
                        actual: await applications.probe(bundleIdentifier: bundleIdentifier).state,
                        expected: .running
                    ),
                    targetIdentifier: bundleIdentifier,
                    profile: profile
                )
            )
        }
        for executableName in snapshot.activeProcessNames.sorted() {
            guard let process = profile.processes.first(where: { $0.executableName == executableName }) else {
                continue
            }
            guard profile.policy(for: executableName).disposition == .stop else { continue }
            let savedState =
                snapshot.processes.first(where: { $0.executableName == executableName })
                ?? StoredProcess(executableName: executableName, processIdentifiers: [])
            results.append(
                applyFailurePolicy(
                    to: await verifyRestoredProcess(process, savedState: savedState),
                    targetIdentifier: executableName,
                    profile: profile
                )
            )
        }
        return results.sorted(by: resultSort)
    }

    public func preflight(profile: CleanroomProfile) async -> PreflightReport {
        let checkedAt = Date()
        var ownership: [PreflightFinding] = []

        switch await probeService(label: Self.legacyAgentLabel) {
        case .running:
            ownership.append(
                PreflightFinding(
                    id: "legacy-agent",
                    severity: .critical,
                    category: "Ownership",
                    summary: "Legacy Roblox watcher is still loaded",
                    detail: "Two state owners could overwrite each other's recovery data.",
                    remediation: "Run cleanroomctl migrate-legacy while Roblox is closed."
                ))
        case .unknown:
            ownership.append(
                PreflightFinding(
                    id: "legacy-agent-unknown",
                    severity: .critical,
                    category: "Ownership",
                    summary: "Legacy watcher ownership is unknown",
                    detail: "Cleanroom cannot prove that it is the only state owner.",
                    remediation: "Repair launchctl access, then run preflight again before entering Cleanroom."
                ))
        case .stopped:
            break
        }

        var managedApplications: [PreflightFinding] = []
        for application in profile.applications {
            switch await applications.probe(bundleIdentifier: application.bundleIdentifier).state {
            case .running:
                managedApplications.append(
                    PreflightFinding(
                        id: "managed-app-\(application.bundleIdentifier)",
                        severity: .information,
                        category: "Managed app",
                        summary: "\(application.name) is active",
                        detail: "Cleanroom will stop it for the session and restore it afterward."
                    ))
            case .unknown:
                managedApplications.append(
                    PreflightFinding(
                        id: "managed-app-unknown-\(application.bundleIdentifier)",
                        severity: .warning,
                        category: "Managed app",
                        summary: "\(application.name) state is unknown",
                        detail: "Cleanroom could not complete this managed-application probe.",
                        remediation: "Re-run preflight before competitive play."
                    ))
            case .stopped:
                break
            }
        }

        let groups: [(String, String, [PreflightFinding])] = [
            ("ownership", "State ownership", ownership),
            ("managed-applications", "Managed applications", managedApplications),
            ("process-load", "Process load", await processLoadFindings(profile: profile)),
            ("time-machine", "Time Machine", await timeMachineFindings()),
            ("input", "Input devices and hooks", await inputFindings(profile: profile)),
            ("network", "Network path", await networkFindings()),
            ("power-thermal", "Power and thermal state", await powerAndThermalFindings()),
        ]
        var findings = groups.flatMap(\.2)
        let probes = groups.map { id, name, groupFindings in
            preflightProbeEvidence(
                id: id,
                name: name,
                findings: groupFindings,
                checkedAt: checkedAt
            )
        }

        if findings.isEmpty, probes.allSatisfy({ $0.state == .succeeded }) {
            findings.append(
                PreflightFinding(
                    id: "ready",
                    severity: .information,
                    category: "Readiness",
                    summary: "No competitive blockers detected",
                    detail: "The automated checks found no active interference."
                ))
        }
        return PreflightReport(generatedAt: checkedAt, findings: findings, probes: probes)
    }

    private func preflightProbeEvidence(
        id: String,
        name: String,
        findings: [PreflightFinding],
        checkedAt: Date
    ) -> PreflightProbeEvidence {
        let incomplete = findings.contains { $0.id.contains("unknown") }
        if !incomplete { preflightSuccesses[id] = checkedAt }
        return PreflightProbeEvidence(
            id: id,
            name: name,
            state: incomplete ? .incomplete : .succeeded,
            checkedAt: checkedAt,
            lastSucceededAt: preflightSuccesses[id]
        )
    }

    public func sampleNetworkLatency(sampleCount requestedCount: Int) async -> NetworkLatencyReport {
        let sampleCount = min(max(requestedCount, 1), 20)
        let routeArguments = ["-n", "get", "default"]
        let route = await commands.run("/sbin/route", arguments: routeArguments, timeout: 4)
        var observations = [CommandObservation(executable: "/sbin/route", arguments: routeArguments)]
        guard route.succeeded,
            let gateway = route.standardOutput.split(separator: "\n").compactMap({ line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.first == "gateway:", fields.count == 2 else { return nil }
                return String(fields[1])
            }).first,
            gateway.range(of: #"^[0-9a-fA-F:.%]+$"#, options: .regularExpression) != nil
        else {
            return NetworkLatencyReport(
                target: nil,
                sampleCount: 0,
                averageMilliseconds: nil,
                jitterMilliseconds: nil,
                packetLossPercent: nil,
                error: route.succeeded ? "The active default gateway could not be parsed." : commandFailure(route),
                commands: observations
            )
        }

        let pingArguments = ["-n", "-q", "-c", String(sampleCount), "-W", "1000", gateway]
        observations.append(CommandObservation(executable: "/sbin/ping", arguments: pingArguments))
        let ping = await commands.run(
            "/sbin/ping", arguments: pingArguments, timeout: TimeInterval(sampleCount + 3))
        let loss = Self.packetLoss(from: ping.standardOutput)
        let timing = Self.roundTripTiming(from: ping.standardOutput)
        return NetworkLatencyReport(
            target: gateway,
            sampleCount: sampleCount,
            averageMilliseconds: timing?.average,
            jitterMilliseconds: timing?.jitter,
            packetLossPercent: loss,
            error: ping.succeeded ? nil : commandFailure(ping),
            commands: observations
        )
    }

    public func sampleSystemPressure() async -> SystemPressureSample {
        let battery = await commands.run("/usr/bin/pmset", arguments: ["-g", "batt"], timeout: 3)
        let output = battery.succeeded ? battery.standardOutput : ""
        let percentage = output.range(of: #"[0-9]{1,3}%"#, options: .regularExpression).flatMap {
            Int(output[$0].dropLast())
        }
        let onACPower: Bool? = battery.succeeded ? output.contains("AC Power") : nil
        let thermal: ThermalPressureLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        return SystemPressureSample(
            thermal: thermal,
            batteryPercent: percentage,
            onACPower: onACPower
        )
    }

    private static func packetLoss(from output: String) -> Double? {
        for component in output.split(separator: ",") where component.contains("packet loss") {
            guard let token = component.split(whereSeparator: \.isWhitespace).first(where: { $0.contains("%") })
            else { continue }
            return Double(token.replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    private static func roundTripTiming(from output: String) -> (average: Double, jitter: Double)? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
            let values = line.split(separator: "=").last?.split(separator: "/"),
            values.count >= 4,
            let average = Double(values[1].trimmingCharacters(in: .whitespaces)),
            let jitter = Double(values[3].split(whereSeparator: \.isWhitespace).first ?? "")
        else { return nil }
        return (average, jitter)
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
        let storedPreferences = Set(
            snapshot.preferences.map { "\($0.domain)\u{0}\($0.key)\u{0}\($0.kind.rawValue)" }
        )
        invalid += allowedPreferences.subtracting(storedPreferences).sorted().map { key in
            let fields = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
            return fields.count >= 2 ? "missing \(fields[0]):\(fields[1])" : "missing preference"
        }
        guard !invalid.isEmpty else { return [] }
        return [
            ActionResult(
                action: "validate recovery snapshot",
                target: "recovery.json",
                outcome: .failed,
                detail: "Snapshot is invalid or incomplete: \(invalid.joined(separator: ", "))."
            )
        ]
    }

    /// Retries idempotent shell operations (defaults read/write/delete) that
    /// fail transiently when cfprefsd is contended — e.g. exit 255 writes or
    /// "domain not found" reads while the Dock is restarting.
    private func runWithRetry(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        attempts: Int = 3
    ) async -> CommandResult {
        var result = await commands.run(executable, arguments: arguments, timeout: timeout)
        var remaining = attempts - 1
        while !result.succeeded, remaining > 0 {
            try? await Task.sleep(for: .milliseconds(300))
            result = await commands.run(executable, arguments: arguments, timeout: timeout)
            remaining -= 1
        }
        return result
    }

    private func applyBuiltInTrackpad(profile: CleanroomProfile) async -> ActionResult {
        let observation = await trackpad.observe()
        let desired = BuiltInTrackpadPolicy.desiredSuppressed(
            enabledInProfile: profile.suppressBuiltInTrackpadWhenLidOpen,
            lid: observation.lid,
            externalPointer: observation.externalPointer,
            builtInTrackpadPresent: observation.builtInTrackpadPresent,
            currentlySuppressed: observation.currentlySuppressed
        )
        if desired == observation.currentlySuppressed {
            return ActionResult(
                action: desired ? "suppress built-in trackpad" : "leave built-in trackpad",
                target: "built-in-trackpad",
                outcome: .skipped,
                detail: desired
                    ? "Already suppressed."
                    : "Conditions do not require built-in trackpad suppression."
            )
        }
        if desired {
            if !observation.listenEventAccessGranted {
                return ActionResult(
                    action: "suppress built-in trackpad",
                    target: "built-in-trackpad",
                    outcome: .warning,
                    detail: "Input Monitoring is not granted."
                )
            }
            return await trackpad.suppress()
        }
        return await trackpad.restore()
    }

    private func verifyBuiltInTrackpad(profile: CleanroomProfile) async -> ActionResult {
        let observation = await trackpad.observe()
        let desired = BuiltInTrackpadPolicy.desiredSuppressed(
            enabledInProfile: profile.suppressBuiltInTrackpadWhenLidOpen,
            lid: observation.lid,
            externalPointer: observation.externalPointer,
            builtInTrackpadPresent: observation.builtInTrackpadPresent,
            currentlySuppressed: observation.currentlySuppressed
        )
        let outcome = BuiltInTrackpadPolicy.verifyOutcome(
            desired: desired,
            currentlySuppressed: observation.currentlySuppressed,
            listenEventAccessGranted: observation.listenEventAccessGranted
        )
        let detail: String
        switch outcome {
        case .succeeded:
            detail = "Built-in trackpad remains suppressed."
        case .skipped:
            detail = "Built-in trackpad suppression is not required."
        case .warning:
            detail = "Input Monitoring is not granted; the built-in trackpad was not seized."
        case .failed:
            detail =
                desired
                ? "Built-in trackpad should be suppressed."
                : "Built-in trackpad should be released."
        case .unknown:
            detail = "Built-in trackpad state could not be verified."
        }
        return ActionResult(
            action: "verify built-in trackpad",
            target: "built-in-trackpad",
            outcome: outcome,
            detail: detail
        )
    }

    private func restoreBuiltInTrackpad() async -> ActionResult {
        await trackpad.restore()
    }

    private func readPreference(_ preference: PreferenceAction) async throws -> StoredPreference {
        try await preferences.readStored(preference)
    }

    /// Writes the target value only when the current value differs, so a
    /// no-op apply never disturbs cfprefsd or triggers a synchronize.
    private func writePreferenceIfNeeded(_ preference: PreferenceAction) async
        -> (result: ActionResult, changed: Bool)
    {
        let target = "\(preference.domain):\(preference.key)"
        let original = try? await readPreference(preference)
        if let current = original,
            current.wasPresent,
            valuesMatch(current.value, preference.activeValue, kind: preference.kind)
        {
            return (
                ActionResult(
                    action: "apply preference",
                    target: target,
                    outcome: .skipped,
                    detail: "Already at the target value."
                ),
                false
            )
        }
        let result = await runWithRetry(
            "/usr/bin/defaults",
            arguments: [
                "write", preference.domain, preference.key,
                defaultsFlag(preference.kind), defaultsWriteValue(preference.activeValue, kind: preference.kind),
            ],
            timeout: 3
        )
        guard result.succeeded else {
            return (
                ActionResult(
                    action: "apply preference",
                    target: target,
                    outcome: .failed,
                    detail: commandFailure(result)
                ),
                false
            )
        }
        do {
            let actual = try await readPreference(preference)
            guard actual.wasPresent,
                valuesMatch(actual.value, preference.activeValue, kind: preference.kind)
            else {
                return (
                    ActionResult(
                        action: "apply preference",
                        target: target,
                        outcome: .failed,
                        detail: "Write completed, but readback did not match the target value."
                    ),
                    false
                )
            }
        } catch {
            return (
                ActionResult(
                    action: "apply preference",
                    target: target,
                    outcome: .unknown,
                    detail: "Write completed, but readback failed: \(error.localizedDescription)"
                ),
                false
            )
        }
        return (
            ActionResult(
                action: "apply preference",
                target: target,
                outcome: .succeeded,
                detail: "Set and verified at \(preference.activeValue)."
            ),
            original != nil
        )
    }

    /// Restores the saved value only when the current value differs from it.
    private func restorePreferenceIfNeeded(_ stored: StoredPreference) async
        -> (result: ActionResult, changed: Bool)
    {
        let target = "\(stored.domain):\(stored.key)"
        let probe = PreferenceAction(
            domain: stored.domain,
            key: stored.key,
            kind: stored.kind,
            activeValue: stored.value ?? ""
        )
        let original = try? await readPreference(probe)
        if let current = original,
            current.wasPresent == stored.wasPresent,
            !stored.wasPresent || valuesMatch(current.value, stored.value, kind: stored.kind)
        {
            return (
                ActionResult(
                    action: "restore preference",
                    target: target,
                    outcome: .skipped,
                    detail: "Already matches the saved state."
                ),
                false
            )
        }

        let arguments: [String]
        if stored.wasPresent, let value = stored.value {
            arguments = [
                "write", stored.domain, stored.key, defaultsFlag(stored.kind),
                defaultsWriteValue(value, kind: stored.kind),
            ]
        } else {
            arguments = ["delete", stored.domain, stored.key]
        }
        let result = await runWithRetry("/usr/bin/defaults", arguments: arguments, timeout: 3)
        var deletionAlreadySatisfied = false
        if !stored.wasPresent, !result.succeeded {
            if let actual = try? await readPreference(probe) {
                deletionAlreadySatisfied = !actual.wasPresent
            }
        }
        guard result.succeeded || deletionAlreadySatisfied else {
            return (
                ActionResult(
                    action: "restore preference",
                    target: target,
                    outcome: .failed,
                    detail: commandFailure(result)
                ),
                false
            )
        }
        do {
            let actual = try await readPreference(probe)
            guard actual.wasPresent == stored.wasPresent,
                !stored.wasPresent || valuesMatch(actual.value, stored.value, kind: stored.kind)
            else {
                return (
                    ActionResult(
                        action: "restore preference",
                        target: target,
                        outcome: .failed,
                        detail: "Restore completed, but readback did not match the recovery journal."
                    ),
                    false
                )
            }
        } catch {
            return (
                ActionResult(
                    action: "restore preference",
                    target: target,
                    outcome: .unknown,
                    detail: "Restore completed, but readback failed: \(error.localizedDescription)"
                ),
                false
            )
        }
        return (
            ActionResult(
                action: "restore preference",
                target: target,
                outcome: .succeeded,
                detail: stored.wasPresent ? "Restored and verified saved value." : "Restored and verified key absence."
            ),
            original != nil
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

    private func synchronizeProcesses(_ processNames: Set<String>) async -> [ActionResult] {
        var results: [ActionResult] = []
        for name in processNames.sorted() {
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

        // Success is defined by the postcondition, not by bootout's exit code:
        // bootout exits non-zero when the service unloaded on its own between
        // the probe and the command, which is still the desired end state.
        var lastFailure = "Service did not unload."
        for attempt in 1...3 {
            let result = await commands.run(
                "/bin/launchctl",
                arguments: ["bootout", "gui/\(userIdentifier)/\(service.label)"],
                timeout: 5
            )
            let postcondition = await probeService(label: service.label)
            switch postcondition {
            case .stopped:
                let detail =
                    attempt == 1
                    ? "Unloaded for this session."
                    : "Unloaded for this session after \(attempt) attempts."
                return ActionResult(
                    action: "stop service", target: service.name, outcome: .succeeded, detail: detail)
            case .unknown:
                return ActionResult(
                    action: "stop service", target: service.name, outcome: .unknown,
                    detail: "Service state could not be determined after bootout.")
            case .running:
                lastFailure = commandFailure(result)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return ActionResult(
            action: "stop service", target: service.name, outcome: .failed,
            detail: "Still loaded after 3 attempts. \(lastFailure)")
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
        switch await waitForServiceState(service.label, timeout: 4) {
        case .running:
            return ActionResult(
                action: "restore service",
                target: service.name,
                outcome: .succeeded,
                detail: result.succeeded
                    ? "Reloaded from its saved LaunchAgent."
                    : "The service reached its running postcondition despite bootstrap reporting: \(commandFailure(result))"
            )
        case .unknown:
            return ActionResult(
                action: "restore service",
                target: service.name,
                outcome: .unknown,
                detail: "Service state could not be determined after bootstrap."
            )
        case .stopped:
            return ActionResult(
                action: "restore service",
                target: service.name,
                outcome: .failed,
                detail: commandFailure(result)
            )
        }
    }

    private func waitForServiceState(_ label: String, timeout: TimeInterval) async -> ProbeState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await probeService(label: label)
            if state != .stopped { return state }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await probeService(label: label)
    }

    private func probeProcessIdentity(executableName: String) async -> (
        state: ProbeState,
        processIdentifiers: [Int32],
        executableURLs: [URL]
    ) {
        let result = await commands.run(
            "/usr/bin/pgrep",
            arguments: ["-U", "\(userIdentifier)", "-x", executableName],
            timeout: 3
        )
        if result.succeeded {
            let processIdentifiers = result.standardOutput.split(whereSeparator: \.isWhitespace).compactMap {
                Int32($0)
            }
            guard !processIdentifiers.isEmpty else { return (.unknown, [], []) }
            var executableURLs: [URL] = []
            for processIdentifier in processIdentifiers {
                let identity = await commands.run(
                    "/bin/ps",
                    arguments: ["-p", "\(processIdentifier)", "-o", "comm="],
                    timeout: 3
                )
                let path = identity.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard identity.succeeded,
                    let executableURL = Self.processExecutableURL(
                        processIdentifier: processIdentifier,
                        reportedPath: path
                    )
                else { return (.unknown, [], []) }
                executableURLs.append(executableURL)
            }
            return (.running, processIdentifiers, executableURLs)
        }
        if !result.timedOut, result.launchError == nil, result.exitCode == 1 { return (.stopped, [], []) }
        return (.unknown, [], [])
    }

    static func processExecutableURL(processIdentifier: Int32, reportedPath: String) -> URL? {
        if reportedPath.hasPrefix("/") { return URL(fileURLWithPath: reportedPath) }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = buffer.withUnsafeBytes {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return URL(fileURLWithPath: path)
    }

    private func probeProcess(executableName: String) async -> ProbeState {
        await probeProcessIdentity(executableName: executableName).state
    }

    private func stopProcess(_ process: ManagedProcess) async -> ActionResult {
        let initialState = await probeProcess(executableName: process.executableName)
        if initialState == .stopped {
            return ActionResult(
                action: "stop process", target: process.name, outcome: .skipped, detail: "Was already stopped.")
        }
        if initialState == .unknown {
            return ActionResult(
                action: "stop process", target: process.name, outcome: .unknown,
                detail: "Process state could not be determined.")
        }

        // Success is defined by the postcondition probe, not by pkill's exit
        // code: pkill exits 1 when the process exited on its own between the
        // probe and the signal, which is still the desired end state.
        var lastFailure = "Process did not exit."
        for attempt in 1...3 {
            _ = await commands.run(
                "/usr/bin/pkill",
                arguments: ["-TERM", "-U", "\(userIdentifier)", "-x", process.executableName],
                timeout: 3
            )
            if await waitUntilProcessStopped(process.executableName, timeout: 1.5) {
                let detail =
                    attempt == 1
                    ? "Terminated gracefully."
                    : "Terminated gracefully after \(attempt) attempts."
                return ActionResult(
                    action: "stop process", target: process.name, outcome: .succeeded, detail: detail)
            }

            let forced = await commands.run(
                "/usr/bin/pkill",
                arguments: ["-KILL", "-U", "\(userIdentifier)", "-x", process.executableName],
                timeout: 3
            )
            if await waitUntilProcessStopped(process.executableName, timeout: 1) {
                return ActionResult(
                    action: "stop process", target: process.name, outcome: .succeeded,
                    detail: "Force-terminated after grace period.")
            }
            lastFailure = commandFailure(forced)
            if await probeProcess(executableName: process.executableName) == .unknown {
                return ActionResult(
                    action: "stop process", target: process.name, outcome: .unknown,
                    detail: "Process state could not be determined after termination.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ActionResult(
            action: "stop process", target: process.name, outcome: .failed,
            detail: "Still running after 3 attempts. \(lastFailure)")
    }

    private func waitUntilProcessStopped(_ executableName: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeProcess(executableName: executableName) == .stopped { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await probeProcess(executableName: executableName) == .stopped
    }

    private func restoreProcess(_ process: ManagedProcess, savedState: StoredProcess) async -> ActionResult {
        let current = await probeProcessIdentity(executableName: process.executableName)
        if current.state == .running {
            let currentPIDs = Set(current.processIdentifiers)
            let originalPIDs = Set(savedState.processIdentifiers)
            let currentExecutables = canonicalExecutableURLs(current.executableURLs)
            let savedExecutables = canonicalExecutableURLs(savedState.executableURLs)
            if !savedExecutables.isEmpty, currentExecutables.isDisjoint(with: savedExecutables) {
                return ActionResult(
                    action: "restore process",
                    target: process.name,
                    outcome: .failed,
                    detail: "A same-named process is running from a different executable than the recovery journal."
                )
            }
            let detail =
                currentPIDs.isDisjoint(with: originalPIDs)
                ? "A matching process was independently relaunched as PID \(currentPIDs.sorted())."
                : "The original recorded process remains running as PID \(currentPIDs.sorted())."
            return ActionResult(
                action: "restore process",
                target: process.name,
                outcome: savedState.processIdentifiers.isEmpty ? .skipped : .warning,
                detail: savedState.processIdentifiers.isEmpty
                    ? "Already running; legacy journal has no PID provenance." : detail
            )
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
            let relaunched = await probeProcessIdentity(executableName: process.executableName)
            let expectedExecutables = canonicalExecutableURLs(savedState.executableURLs)
            let actualExecutables = canonicalExecutableURLs(relaunched.executableURLs)
            if relaunched.state == .running,
                expectedExecutables.isEmpty || !actualExecutables.isDisjoint(with: expectedExecutables)
            {
                return ActionResult(
                    action: "restore process", target: process.name, outcome: .succeeded,
                    detail: "Relaunched saved process as PID \(started.standardOutput).")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return ActionResult(
            action: "restore process", target: process.name, outcome: .warning,
            detail:
                "Relaunch command ran, but the process was not observed during the launch wait; final verification decides completion."
        )
    }

    private func verifyRestoredProcess(
        _ process: ManagedProcess,
        savedState: StoredProcess
    ) async -> ActionResult {
        let current = await probeProcessIdentity(executableName: process.executableName)
        guard current.state == .running else {
            return probeResult(
                action: "verify restored process",
                target: process.name,
                actual: current.state,
                expected: .running
            )
        }
        let expectedExecutables = canonicalExecutableURLs(savedState.executableURLs)
        let actualExecutables = canonicalExecutableURLs(current.executableURLs)
        guard expectedExecutables.isEmpty || !actualExecutables.isDisjoint(with: expectedExecutables) else {
            return ActionResult(
                action: "verify restored process",
                target: process.name,
                outcome: .failed,
                detail: "A same-named process is running from a different executable than the recovery journal."
            )
        }
        return ActionResult(
            action: "verify restored process",
            target: process.name,
            outcome: .succeeded,
            detail: "Postcondition and executable provenance verified."
        )
    }

    private func canonicalExecutableURLs(_ urls: [URL]) -> Set<URL> {
        Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL })
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
        guard result.succeeded else {
            return [
                PreflightFinding(
                    id: "time-machine-unknown",
                    severity: .warning,
                    category: "Storage",
                    summary: "Time Machine activity is unknown",
                    detail: commandFailure(result),
                    remediation: "Re-run preflight before competitive play."
                )
            ]
        }
        guard result.standardOutput.contains("Running = 1") else {
            if result.standardOutput.contains("Running = 0") { return [] }
            return [
                PreflightFinding(
                    id: "time-machine-unknown",
                    severity: .warning,
                    category: "Storage",
                    summary: "Time Machine returned an unrecognized status",
                    detail: result.standardOutput,
                    remediation: "Check Time Machine manually, then re-run preflight."
                )
            ]
        }
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

    private func inputFindings(profile: CleanroomProfile) async -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        let karabiner = await commands.run(
            "/usr/bin/pgrep",
            arguments: ["-U", "\(userIdentifier)", "-if", "karabiner|VirtualHID"],
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

        let observation = await trackpad.observe()
        switch observation.externalPointer {
        case .present:
            findings.append(
                PreflightFinding(
                    id: "external-pointer-ready",
                    severity: .information,
                    category: "Input",
                    summary: "External gameplay pointer detected",
                    detail: "The built-in trackpad can be seized while the lid is open and this pointer is present."
                ))
        case .absent:
            findings.append(
                PreflightFinding(
                    id: "external-mouse-missing",
                    severity: .critical,
                    category: "Input",
                    summary: "External mouse was not detected",
                    detail: "The built-in trackpad stays on unless an external pointing device is present.",
                    remediation: "Connect the gameplay mouse before launching Roblox."
                ))
        case .unknown:
            findings.append(
                PreflightFinding(
                    id: "pointer-scan-unknown",
                    severity: .warning,
                    category: "Input",
                    summary: "External pointer state is unknown",
                    detail: "Cleanroom could not inspect HID pointing devices.",
                    remediation: "Confirm the gameplay mouse is connected."
                ))
        }

        switch observation.lid {
        case .open:
            findings.append(
                PreflightFinding(
                    id: "lid-open",
                    severity: .information,
                    category: "Input",
                    summary: "Laptop lid is open",
                    detail: "The built-in trackpad will be disabled when an external pointer is present."
                ))
        case .closed:
            findings.append(
                PreflightFinding(
                    id: "lid-closed",
                    severity: .information,
                    category: "Input",
                    summary: "Laptop lid is closed",
                    detail: "The built-in trackpad is already unused in clamshell mode."
                ))
        case .unknown:
            findings.append(
                PreflightFinding(
                    id: "lid-state-unknown",
                    severity: .warning,
                    category: "Input",
                    summary: "Laptop lid state is unknown",
                    detail: "Cleanroom will not change built-in trackpad suppression based on lid state.",
                    remediation: "Re-run preflight if accidental trackpad input is a concern."
                ))
        }

        if profile.suppressBuiltInTrackpadWhenLidOpen, !observation.listenEventAccessGranted {
            findings.append(
                PreflightFinding(
                    id: "input-monitoring-missing",
                    severity: .warning,
                    category: "Input",
                    summary: "Input Monitoring is not granted",
                    detail:
                        "Hard-disabling the built-in trackpad needs Input Monitoring. USBMouseStopsTrackpad still applies.",
                    remediation:
                        "System Settings → Privacy & Security → Input Monitoring → enable Cleanroom (and cleanroom-agent if listed)."
                ))
        }
        return findings
    }

    private func networkFindings() async -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        let vpn = await commands.run("/usr/sbin/scutil", arguments: ["--nc", "list"], timeout: 4)
        if !vpn.succeeded {
            findings.append(
                PreflightFinding(
                    id: "vpn-scan-unknown",
                    severity: .warning,
                    category: "Network",
                    summary: "VPN connection state is unknown",
                    detail: commandFailure(vpn),
                    remediation: "Confirm the intended network path, then re-run preflight."
                ))
        } else if vpn.standardOutput.contains("(Connected)") {
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
        } else {
            findings.append(
                PreflightFinding(
                    id: "route-scan-unknown",
                    severity: .warning,
                    category: "Network",
                    summary: "IPv4 route state is unknown",
                    detail: commandFailure(routes),
                    remediation: "Re-run preflight before competitive play."
                ))
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
        let activePowerSource = battery.succeeded ? Self.activePowerSource(from: battery.standardOutput) : nil
        if !battery.succeeded || activePowerSource == nil {
            findings.append(
                PreflightFinding(
                    id: "power-source-unknown",
                    severity: .warning,
                    category: "Power",
                    summary: "Active power source is unknown",
                    detail: battery.succeeded ? battery.standardOutput : commandFailure(battery),
                    remediation: "Confirm AC or battery status, then re-run preflight."
                ))
        } else if activePowerSource == "Battery Power" {
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
        if !power.succeeded {
            findings.append(
                PreflightFinding(
                    id: "power-profile-unknown",
                    severity: .warning,
                    category: "Power",
                    summary: "Power profile could not be inspected",
                    detail: commandFailure(power),
                    remediation: "Re-run preflight before competitive play."
                ))
        } else if let activePowerSource,
            let lowPowerModeEnabled = Self.lowPowerModeEnabled(
                in: power.standardOutput,
                activePowerSource: activePowerSource
            )
        {
            guard lowPowerModeEnabled else { return findings }
            findings.append(
                PreflightFinding(
                    id: "low-power-mode",
                    severity: .critical,
                    category: "Power",
                    summary: "Low Power Mode is enabled",
                    detail: "Low Power Mode can reduce sustained performance.",
                    remediation: "Disable Low Power Mode before competitive play."
                ))
        } else if activePowerSource != nil {
            findings.append(
                PreflightFinding(
                    id: "power-profile-unknown",
                    severity: .warning,
                    category: "Power",
                    summary: "Active Low Power Mode state is unknown",
                    detail: "pmset did not report Low Power Mode for the active power profile.",
                    remediation: "Check Battery settings, then re-run preflight."
                ))
        }
        return findings
    }

    static func activePowerSource(from output: String) -> String? {
        guard let start = output.range(of: "Now drawing from '")?.upperBound,
            let end = output[start...].firstIndex(of: "'")
        else { return nil }
        return String(output[start..<end])
    }

    static func lowPowerModeEnabled(
        in output: String,
        activePowerSource: String
    ) -> Bool? {
        var activeBlock = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(":") {
                activeBlock = trimmed.dropLast().caseInsensitiveCompare(activePowerSource) == .orderedSame
                continue
            }
            guard activeBlock else { continue }
            let fields = trimmed.lowercased().split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "lowpowermode" {
                if fields[1] == "1" { return true }
                if fields[1] == "0" { return false }
                return nil
            }
        }
        return nil
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

    private func applyFailurePolicy(
        to result: ActionResult,
        targetIdentifier: String,
        profile: CleanroomProfile
    ) -> ActionResult {
        guard result.outcome.blocksCompletion,
            profile.policy(for: targetIdentifier).failureSeverity == .warning
        else { return result }
        return ActionResult(
            id: result.id,
            action: result.action,
            target: result.target,
            outcome: .warning,
            detail: "Non-blocking by profile policy: \(result.detail)",
            occurredAt: result.occurredAt
        )
    }

    private func resultSort(_ lhs: ActionResult, _ rhs: ActionResult) -> Bool {
        if lhs.action != rhs.action { return lhs.action < rhs.action }
        return lhs.target < rhs.target
    }
}

private enum RestoreComponent {
    case service(ManagedService)
    case application(ManagedApplication, StoredApplication)
    case process(ManagedProcess, StoredProcess)

    var identifier: String {
        switch self {
        case .service(let service): service.label
        case .application(let application, _): application.bundleIdentifier
        case .process(let process, _): process.executableName
        }
    }

    var displayName: String {
        switch self {
        case .service(let service): service.name
        case .application(let application, _): application.name
        case .process(let process, _): process.name
        }
    }
}
