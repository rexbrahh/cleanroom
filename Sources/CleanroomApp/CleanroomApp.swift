import AppKit
import CleanroomCore
import OSLog
import SwiftUI

@main
@MainActor
struct CleanroomApp: App {
    @NSApplicationDelegateAdaptor(CleanroomAppDelegate.self) private var delegate
    @StateObject private var model: CleanroomViewModel
    private let hotKeys: GlobalHotKeyController
    private static let logger = Logger(subsystem: "com.rex.cleanroom", category: "app")

    init() {
        Self.logger.notice("Cleanroom menu app launched")
        let model = CleanroomViewModel()
        _model = StateObject(wrappedValue: model)
        hotKeys = GlobalHotKeyController { action in model.performGlobalHotKey(action) }
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            CleanroomMenu(model: model)
        } label: {
            // Icon-only: long phase text in the menu bar gets the item hidden
            // outright on notch-limited displays.
            Label(model.phaseTitle, systemImage: model.iconName)
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.menu)

        Window("Cleanroom", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 760, minHeight: 580)
                .task {
                    model.start()
                    model.refreshRepairState()
                }
        }
        .defaultSize(width: 900, height: 700)

        Settings {
            CleanroomSettingsView(model: model)
                .frame(width: 520)
                .onAppear { model.refreshRepairState() }
        }
    }

}

/// Logs a one-time window inventory a few seconds after launch so menu-bar
/// visibility problems are diagnosable from the unified log instead of being
/// indistinguishable from a silent no-op.
final class CleanroomAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.rex.cleanroom", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [logger] in
            let inventory = NSApp.windows
                .map { "\(type(of: $0)) \(NSRectToCGRect($0.frame))" }
                .joined(separator: "; ")
            let hasStatusItem = NSApp.windows.contains {
                String(describing: type(of: $0)) == "NSStatusBarWindow"
            }
            logger.notice(
                "Window inventory (status item: \(hasStatusItem, privacy: .public)): \(inventory, privacy: .public)"
            )
        }
    }
}

private struct CleanroomMenu: View {
    @ObservedObject var model: CleanroomViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(model.phaseTitle)
            Text(model.connectionMessage)
                .foregroundStyle(.secondary)
            Divider()
            Button("Competitive Preflight") { model.runPreflight() }
                .disabled(model.operationInProgress || !model.agentConnected)
                .keyboardShortcut("p")
            Button("Enter / Re-enforce") { model.enter() }
                .disabled(model.operationInProgress || !model.agentConnected)
                .keyboardShortcut("e")
            Button("Safe Launch Roblox") { model.safeLaunch() }
                .disabled(
                    model.operationInProgress || !model.agentConnected
                        || model.status?.trigger.state != .stopped
                )
            Button("Restore Saved State") { model.restore() }
                .disabled(
                    model.operationInProgress || !model.agentConnected || model.status?.journal == nil
                )
                .keyboardShortcut("r")
            Button(model.status?.phase == .paused ? "Resume Automatic Control" : "Pause Automatic Control") {
                model.togglePause()
            }
            .disabled(
                model.operationInProgress || !model.agentConnected
                    || model.status?.incidentMode == true
            )
            Button(model.status?.incidentMode == true ? "Exit Incident Mode" : "Enter Incident Mode") {
                if model.status?.incidentMode == true {
                    model.exitIncidentMode()
                } else {
                    model.enterIncidentMode()
                }
            }
            .disabled(model.operationInProgress || !model.agentConnected)
            Divider()
            Button("Open Cleanroom…") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")
            SettingsLink {
                Text("Settings…")
            }
            Divider()
            Button("Quit Menu Bar App") { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            model.start()
            model.menuOpened()
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: CleanroomViewModel
    @State private var selectedSection: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Cleanroom")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sectionContent
                }
                .padding(24)
            }
        }
        .alert("Discard recovery journal?", isPresented: $model.presentingDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { model.discardJournal() }
        } message: {
            Text(
                "Only discard after manually confirming that pointer, trackpad, hot-corner, app, and window-management state has already been restored."
            )
        }
        .alert(
            "Move leftover copies to Trash?",
            isPresented: $model.presentingLeftoverRemovalConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeLeftoverCopies() }
        } message: {
            Text(
                "This removes extra Cleanroom copies under ~/Applications. The copy in /Applications is kept."
            )
        }
        .alert("Uninstall Cleanroom?", isPresented: $model.presentingUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { model.uninstallCleanroom() }
        } message: {
            Text(uninstallConfirmationMessage(purgeData: model.uninstallPurgeData))
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection ?? .overview {
        case .overview:
            if model.setupDoctorVisible {
                setupDoctorCard
            }
            if model.repairCardVisible {
                repairCard
            }
            healthCard
            agentCard
            if model.status?.phase == .degraded || model.status?.journal != nil {
                recoveryCard
            }
            controls
            recentResults
        case .preflight:
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Competitive readiness").font(.headline)
                    Text("Read-only inspection of input, load, power, thermals, and networking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sample Latency") { model.sampleNetworkLatency() }
                    .disabled(model.operationInProgress || !model.agentConnected)
                Button("Run Preflight") { model.runPreflight() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.operationInProgress || !model.agentConnected)
            }
            preflightCard
            if let latency = model.networkLatency {
                GroupBox("Active-route latency") {
                    Text(
                        latency.error
                            ?? "\(latency.averageMilliseconds.map { String(format: "%.2f", $0) } ?? "—") ms average · \(latency.jitterMilliseconds.map { String(format: "%.2f", $0) } ?? "—") ms jitter · no network changes"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .activity:
            recentResults
            recoveryHistoryCard
            performanceTimelineCard
            activityCard
            diagnosticsCard
        case .policy:
            profileEditorCard
            policyCard
        }
    }

    private var healthCard: some View {
        HStack(spacing: 12) {
            metric(
                title: "Agent",
                value: model.agentHealthTitle,
                systemImage: model.agentHealth == .healthy ? "checkmark.circle.fill" : "waveform.path.ecg",
                tint: agentHealthColor
            )
            metric(
                title: "Session",
                value: model.sessionDetail,
                systemImage: model.status?.journal == nil ? "lock.open" : "lock.shield.fill",
                tint: model.status?.journal == nil ? .secondary : .green
            )
            metric(
                title: "Readiness",
                value: model.preflightSummary,
                systemImage: "checklist",
                tint: readinessColor
            )
        }
    }

    private var setupDoctorCard: some View {
        GroupBox("First-run Setup Doctor") {
            VStack(alignment: .leading, spacing: 12) {
                setupRow(
                    title: "Background agent registration",
                    detail: model.registrationMessage,
                    complete: model.agentRegistrationReady
                )
                setupRow(
                    title: "Authenticated agent connection",
                    detail: model.agentConnected ? "Live XPC status received" : model.connectionMessage,
                    complete: model.agentConnected
                )
                setupRow(
                    title: "Notification permission",
                    detail: model.notificationMessage,
                    complete: model.notificationsEnabled
                )
                setupRow(
                    title: "Login-item approval",
                    detail: model.launchAtLoginMessage,
                    complete: model.launchAtLoginBound
                )
                setupRow(
                    title: "Menu-item checkpoint",
                    detail: model.menuItemConfirmed
                        ? "Menu-bar item confirmed manually"
                        : "Open the menu-bar item, then confirm it is visible",
                    complete: model.menuItemConfirmed
                )
                HStack {
                    if !model.agentRegistrationReady {
                        Button("Open Login Items") { model.openLoginItemsSettings() }
                        Button("Replace Registration") { model.registerAgent() }
                    }
                    if !model.notificationsEnabled {
                        Button("Enable Notifications") { model.setNotificationsEnabled(true) }
                    }
                    if !model.launchAtLoginBound {
                        Button("Enable Launch at Login") { model.setLaunchAtLoginEnabled(true) }
                    }
                    if !model.menuItemConfirmed {
                        Button("I Can See the Menu Item") { model.confirmMenuItemVisible() }
                    }
                    Spacer()
                    Button("Finish Setup") { model.completeSetupDoctor() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.setupDoctorState.canComplete)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var repairCard: some View {
        GroupBox("Repair") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.repairIssues, id: \.self) { issue in
                    setupRow(
                        title: model.title(for: issue),
                        detail: model.detail(for: issue),
                        complete: false
                    )
                }
                HStack {
                    if model.repairIssues.contains(where: {
                        if case .leftoverUserSpaceCopies = $0 { return true }
                        return false
                    }) {
                        Button("Move Leftover Copies to Trash…") {
                            model.presentingLeftoverRemovalConfirmation = true
                        }
                    }
                    if model.repairIssues.contains(.loginItemNeedsApproval)
                        || model.repairIssues.contains(.agentNeedsApproval)
                    {
                        Button("Open Login Items") { model.openLoginItemsSettings() }
                    }
                    if model.repairIssues.contains(.loginItemNeedsRebind) {
                        Button("Repair Login Item") { model.setLaunchAtLoginEnabled(true) }
                    }
                    if model.repairIssues.contains(.agentNeedsApproval)
                        || model.repairIssues.contains(.agentUnreachable)
                    {
                        Button("Replace Agent Registration") { model.registerAgent() }
                    }
                    Button("Uninstall Cleanroom…", role: .destructive) {
                        model.presentingUninstallConfirmation = true
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setupRow(title: String, detail: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: model.iconName)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(phaseColor)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.phaseTitle).font(.title2.weight(.semibold))
                Text(model.connectionMessage).foregroundStyle(.secondary)
            }
            Spacer()
            if model.operationInProgress { ProgressView().controlSize(.small) }
        }
    }

    private var agentCard: some View {
        GroupBox("Background agent") {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.registrationMessage)
                    if let heartbeat = model.status?.heartbeatAt {
                        Text("Heartbeat \(heartbeat.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let diagnostics = model.diagnosticsHealthMessage {
                        Text("Diagnostics degraded: \(diagnostics)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if model.registrationMessage.contains("approval") {
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                } else if model.preflight?.findings.contains(where: { $0.id == "legacy-agent" }) == true {
                    Button("Migrate Legacy Watcher") { model.migrateLegacy() }
                } else if !model.agentConnected {
                    Button("Replace Agent Registration") { model.registerAgent() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var recoveryCard: some View {
        GroupBox("Recovery") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    model.status?.journal == nil
                        ? "Cleanroom detected a degraded condition before saving state."
                        : "The recovery journal is retained until every saved postcondition is verified."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button(
                        model.status?.incidentMode == true ? "Exit Incident Mode" : "Enter Incident Mode"
                    ) {
                        if model.status?.incidentMode == true {
                            model.exitIncidentMode()
                        } else {
                            model.enterIncidentMode()
                        }
                    }
                    Button("Retry Restore") { model.retryRestore() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.status?.journal == nil || model.operationInProgress)
                    Button("Retry Entry") { model.retryEntry() }
                        .disabled(model.operationInProgress)
                    Spacer()
                    Button("Discard Journal…", role: .destructive) {
                        model.presentingDiscardConfirmation = true
                    }
                    .disabled(model.status?.journal == nil || model.operationInProgress)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var controls: some View {
        GroupBox(model.status?.activeProfile?.name ?? "Game profile") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "Active profile",
                    selection: Binding(
                        get: { model.status?.activeProfile?.identifier ?? "" },
                        set: { model.selectProfile($0) }
                    )
                ) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(profile.identifier)
                    }
                }
                .disabled(model.status?.journal != nil || model.operationInProgress)
                HStack {
                    Button("Run Preflight") { model.runPreflight() }
                    Button("Safe Launch") { model.safeLaunch() }
                        .disabled(model.status?.trigger.state != .stopped || model.status?.journal != nil)
                    Button("Enter / Re-enforce") { model.enter() }
                    Button("Restore") { model.restore() }
                        .disabled(model.status?.journal == nil)
                    Spacer()
                    Button(model.status?.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                        .disabled(model.status?.incidentMode == true)
                }
            }
            .disabled(model.operationInProgress || !model.agentConnected)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var preflightCard: some View {
        GroupBox("Competitive preflight") {
            if let report = model.preflight, report.isCurrent() {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.probes ?? []) { probe in
                        HStack {
                            Image(
                                systemName: probe.state == .succeeded
                                    ? "checkmark.circle.fill" : "questionmark.circle.fill"
                            )
                            .foregroundStyle(probe.state == .succeeded ? .green : .orange)
                            Text(probe.name).font(.callout.weight(.medium))
                            Spacer()
                            Text(
                                "last success: \(probe.age(at: Date()).map { "\(Int($0))s ago" } ?? "never")"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if !report.isFreshAndComplete() {
                        Text("Readiness is blocked until every probe succeeds within 120 seconds.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    ForEach(report.findings) { finding in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: severityIcon(finding.severity))
                                .foregroundStyle(severityColor(finding.severity))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.summary).fontWeight(.medium)
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                if let remediation = finding.remediation {
                                    Text(remediation).font(.caption)
                                }
                            }
                        }
                        if finding.id != report.findings.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 4)
            } else if let report = model.preflight {
                Text(
                    "The last preflight expired at \(report.generatedAt.formatted(date: .abbreviated, time: .standard)). Run a new preflight for current findings."
                )
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } else {
                Text(
                    "Run preflight to inspect input hooks, high-load processes, Time Machine, VPN state, external-pointer availability, and thermal pressure."
                )
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var recentResults: some View {
        if let results = model.status?.lastResults, !results.isEmpty {
            GroupBox("Last transition") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(results.suffix(12)) { result in
                        HStack(alignment: .top) {
                            Image(
                                systemName: result.outcome.blocksCompletion
                                    ? "xmark.circle.fill" : "checkmark.circle.fill"
                            )
                            .foregroundStyle(result.outcome.blocksCompletion ? .red : .green)
                            VStack(alignment: .leading) {
                                Text("\(result.action) · \(result.target)").fontWeight(.medium)
                                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var activityCard: some View {
        GroupBox("Activity") {
            if model.recentEvents.isEmpty {
                Text("No recorded transitions yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.recentEvents.prefix(10).enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: eventIcon(event.phase))
                                .foregroundStyle(eventColor(event.phase))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.message).font(.callout.weight(.medium))
                                HStack(spacing: 6) {
                                    Text(event.phase.rawValue.capitalized)
                                    if let occurredAt = event.occurredAt {
                                        Text("·")
                                        Text(occurredAt.formatted(date: .abbreviated, time: .standard))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        if event != model.recentEvents.prefix(10).last { Divider() }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var recoveryHistoryCard: some View {
        GroupBox("Resolved recovery history") {
            if model.recoveryHistory.isEmpty {
                Text("No historical recovery receipts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.recoveryHistory) { receipt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                "Historical receipt · \(receipt.restoredAt.formatted(date: .abbreviated, time: .standard))"
                            )
                            .font(.callout.weight(.medium))
                            Text(
                                "\(receipt.results.count) target postconditions verified; this is not active recovery state."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var performanceTimelineCard: some View {
        GroupBox("Session performance") {
            if model.performanceTimeline.isEmpty {
                Text("No system performance records yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.performanceTimeline.prefix(10)) { record in
                        HStack {
                            Text(record.operation).font(.callout.weight(.medium))
                            Spacer()
                            Text(
                                "\(record.durationMilliseconds) ms · \(record.thermalState) · \(record.failureCount) failures"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text("System metadata only; gameplay content is never recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var diagnosticsCard: some View {
        GroupBox("Diagnostics") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Status, preflight, and the latest bounded transition history")
                    Text("The export records that network checks are observation-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy JSON") { model.copyDiagnostics() }
                Button("Export…") { model.exportDiagnostics() }
                Button("Support Bundle…") { model.exportSupportBundle() }
            }
            Text("Support bundles are redacted, saved locally, and never submitted automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }

    private var policyCard: some View {
        let profile = CleanroomProfile.phantomForces()
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("Managed automatically") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "Only these fixed desktop and input targets can be stopped or changed. Previously running targets are restored from the recovery journal."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(profile.applications) { application in
                        policyRow(
                            name: application.name,
                            detail: application.bundleIdentifier,
                            icon: "app"
                        )
                    }
                    policyRow(
                        name: "Built-in trackpad",
                        detail:
                            "Disabled when the lid is open and an external pointer is present; restored when Roblox quits",
                        icon: "hand.draw"
                    )
                    ForEach(profile.services) { service in
                        policyRow(name: service.name, detail: service.label, icon: "rectangle.stack.badge.minus")
                    }
                    ForEach(profile.processes) { process in
                        policyRow(name: process.name, detail: process.executableName, icon: "terminal")
                    }
                    ForEach(profile.preferences) { preference in
                        policyRow(
                            name: preference.key,
                            detail: preference.domain,
                            icon: "slider.horizontal.3"
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Observed only · operator-controlled") {
                VStack(alignment: .leading, spacing: 10) {
                    policyRow(
                        name: "Network infrastructure",
                        detail:
                            "VPNs, Tailscale, Little Snitch, firewalls, routes, DNS, interfaces, and network extensions",
                        icon: "network"
                    )
                    policyRow(
                        name: "System workloads",
                        detail: "Time Machine, VMs, containers, and macOS services",
                        icon: "externaldrive"
                    )
                    policyRow(
                        name: "Low-level input drivers",
                        detail: "Karabiner DriverKit and VirtualHID services",
                        icon: "keyboard"
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var profileEditorCard: some View {
        let draft = model.profileDraft
        let validation = draft.validationReport()
        return GroupBox("Validated profile editor") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Profile name", text: $model.profileDraftName)
                TextField("Game trigger bundle ID", text: $model.profileDraftTriggerBundleIdentifier)
                Text("Exact automatic mutation preview")
                    .font(.callout.weight(.semibold))
                ForEach(validation.mutations) { mutation in
                    LabeledContent(mutation.action, value: mutation.target)
                        .font(.caption)
                }
                if !validation.errors.isEmpty {
                    ForEach(validation.errors, id: \.self) { error in
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Validate") { model.validateProfileDraft() }
                    Button("Save Custom Profile") { model.saveProfileDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!validation.isValid || model.status?.journal != nil)
                    Button("Import…") { model.importProfile() }
                    Button("Export Active…") { model.exportActiveProfile() }
                    Spacer()
                    Text("\(validation.mutations.count) bounded targets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let preview = model.profileImportPreview {
                    Divider()
                    Text("Import mutation diff")
                        .font(.callout.weight(.semibold))
                    ForEach(preview.addedMutations) { mutation in
                        Text("+ \(mutation.action) · \(mutation.target)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    ForEach(preview.removedMutations) { mutation in
                        Text("− \(mutation.action) · \(mutation.target)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(preview.validation.errors, id: \.self) { error in
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button("Confirm Import") { model.confirmProfileImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!preview.canImport || model.status?.journal != nil)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func policyRow(name: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var agentHealthColor: Color {
        switch model.agentHealth {
        case .healthy: .green
        case .connecting, .delayed: .orange
        case .stale, .unavailable: .red
        }
    }

    private var readinessColor: Color {
        switch model.preflight?.highestSeverity {
        case .critical: .red
        case .warning: .orange
        case .information: .green
        case nil: .secondary
        }
    }

    private func eventIcon(_ phase: CleanroomPhase) -> String {
        switch phase {
        case .active: "scope"
        case .degraded: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .entering, .restoring: "arrow.triangle.2.circlepath"
        case .idle: "checkmark.circle"
        }
    }

    private func eventColor(_ phase: CleanroomPhase) -> Color {
        switch phase {
        case .active: .green
        case .degraded: .red
        case .paused: .orange
        case .entering, .restoring: .blue
        case .idle: .secondary
        }
    }

    private var phaseColor: Color {
        switch model.status?.phase {
        case .active: .green
        case .degraded: .red
        case .entering, .restoring: .blue
        case .paused: .orange
        case .idle, nil: .secondary
        }
    }

    private func severityIcon(_ severity: PreflightSeverity) -> String {
        switch severity {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private func severityColor(_ severity: PreflightSeverity) -> Color {
        switch severity {
        case .information: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case preflight
    case activity
    case policy

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .preflight: "Preflight"
        case .activity: "Activity"
        case .policy: "Policy"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "scope"
        case .preflight: "checklist"
        case .activity: "clock.arrow.circlepath"
        case .policy: "shield.lefthalf.filled"
        }
    }
}

private struct CleanroomSettingsView: View {
    @ObservedObject var model: CleanroomViewModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch the Cleanroom menu app at login",
                    isOn: Binding(
                        get: { model.launchAtLoginDesired },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
                Text(model.launchAtLoginMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.preferredInstall {
                    Text(
                        "This copy is not \(RegistrationRepairPolicy.preferredBundlePath). Login items should bind to that path only."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !model.leftoverCopyURLs.isEmpty {
                    Text(
                        "Leftover copies in ~/Applications can keep this toggle off while System Settings still shows Cleanroom."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Move Leftover Copies to Trash…") {
                        model.presentingLeftoverRemovalConfirmation = true
                    }
                }
                Text("The recovery agent remains registered independently of this menu-bar preference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle(
                    "Notify for degraded state and completed recovery",
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotificationsEnabled($0) }
                    )
                )
                Text(model.notificationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Cleanroom never posts a competitive-mode activation banner during gameplay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Alert on in-session thermal or battery threshold crossings",
                    isOn: Binding(
                        get: { model.performanceAlertsEnabled },
                        set: { model.setPerformanceAlertsEnabled($0) }
                    )
                )
                Picker("Thermal threshold", selection: $model.thermalAlertThreshold) {
                    Text("Serious").tag(ThermalPressureLevel.serious)
                    Text("Critical").tag(ThermalPressureLevel.critical)
                }
                Stepper(
                    "Battery threshold: \(model.batteryAlertThreshold)%",
                    value: $model.batteryAlertThreshold,
                    in: 5...50,
                    step: 5
                )
                Button("Save Alert Thresholds") { model.savePerformanceAlertThresholds() }
            }

            Section("Global hotkeys") {
                Text("Control-Option-Command + S status · P preflight · L safe launch · C pause/resume · R restore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Hotkeys and App Shortcuts call the same authenticated agent commands as the UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Device calibration") {
                Text("Hardware \(model.calibrationHardwareIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use linear pointer input during sessions", isOn: $model.calibrationPointerLinearEnabled)
                Stepper(
                    "Expected display: \(model.calibrationDisplayRefreshRateHertz) Hz",
                    value: $model.calibrationDisplayRefreshRateHertz,
                    in: 30...360,
                    step: 10
                )
                Stepper(
                    "Exit debounce: \(model.calibrationRestoreDebounceSeconds.formatted()) s",
                    value: $model.calibrationRestoreDebounceSeconds,
                    in: 0...30,
                    step: 0.5
                )
                Button("Save for This Mac") { model.saveCalibration() }
                    .disabled(model.calibrationHardwareIdentifier == "unknown")
            }

            Section("Remove") {
                Toggle("Also delete local Cleanroom data", isOn: $model.uninstallPurgeData)
                Text(
                    "Data includes profiles, recovery journals, and previous-install backups. Leave this off to keep them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Uninstall Cleanroom…", role: .destructive) {
                    model.presentingUninstallConfirmation = true
                }
            }

            Section("Build") {
                LabeledContent("Version", value: model.appVersion)
                LabeledContent(
                    "Profile", value: model.status?.activeProfile?.name ?? "Agent unavailable"
                )
                LabeledContent("Network control", value: "Read-only observations")
                LabeledContent("Updates", value: "Manual install")
                Link(
                    "Open Cleanroom Releases",
                    destination: URL(string: "https://github.com/rexbrahh/cleanroom/releases")!
                )
                Text("Cleanroom does not download or install updates from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .alert(
            "Move leftover copies to Trash?",
            isPresented: $model.presentingLeftoverRemovalConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeLeftoverCopies() }
        } message: {
            Text(
                "This removes extra Cleanroom copies under ~/Applications. The copy in /Applications is kept."
            )
        }
        .alert("Uninstall Cleanroom?", isPresented: $model.presentingUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { model.uninstallCleanroom() }
        } message: {
            Text(uninstallConfirmationMessage(purgeData: model.uninstallPurgeData))
        }
    }
}

private func uninstallConfirmationMessage(purgeData: Bool) -> String {
    let base =
        "This unregisters the background agent and login item, moves Cleanroom copies to Trash, and quits."
    if purgeData {
        return base + " Local profiles, recovery journals, and Application Support data will also be deleted."
    }
    return base + " Local profiles and recovery data are kept."
}
