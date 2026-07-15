import AppKit
import CleanroomCore
import SwiftUI

@main
struct CleanroomApp: App {
    @StateObject private var model: CleanroomViewModel

    init() {
        let model = CleanroomViewModel()
        _model = StateObject(wrappedValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            CleanroomMenu(model: model)
        } label: {
            Label(model.phaseTitle, systemImage: model.iconName)
        }
        .menuBarExtraStyle(.menu)

        Window("Cleanroom", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 620, minHeight: 560)
                .task { model.start() }
        }
        .defaultSize(width: 680, height: 680)
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
                .disabled(model.operationInProgress)
            Button("Enter / Re-enforce") { model.enter() }
                .disabled(model.operationInProgress)
            Button("Restore Saved State") { model.restore() }
                .disabled(model.operationInProgress || model.status?.journal == nil)
            Button(model.status?.phase == .paused ? "Resume Automatic Control" : "Pause Automatic Control") {
                model.togglePause()
            }
            .disabled(model.operationInProgress)
            Divider()
            Button("Open Cleanroom…") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button("Quit Menu Bar App") { NSApplication.shared.terminate(nil) }
        }
        .onAppear { model.start() }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: CleanroomViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                agentCard
                if model.status?.phase == .degraded || model.status?.journal != nil {
                    recoveryCard
                }
                controls
                preflightCard
                recentResults
            }
            .padding(24)
        }
        .alert("Discard recovery journal?", isPresented: $model.presentingDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { model.discardJournal() }
        } message: {
            Text(
                "Only discard after manually confirming that pointer, trackpad, hot-corner, app, and window-management state has already been restored."
            )
        }
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
                }
                Spacer()
                if model.registrationMessage.contains("approval") {
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                } else if model.preflight?.findings.contains(where: { $0.id == "legacy-agent" }) == true {
                    Button("Migrate Legacy Watcher") { model.migrateLegacy() }
                } else if model.status == nil {
                    Button("Register Again") { model.registerAgent() }
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
        GroupBox("Roblox / Phantom Forces") {
            HStack {
                Button("Run Preflight") { model.runPreflight() }
                Button("Enter / Re-enforce") { model.enter() }
                Button("Restore") { model.restore() }
                    .disabled(model.status?.journal == nil)
                Spacer()
                Button(model.status?.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
            }
            .disabled(model.operationInProgress)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var preflightCard: some View {
        GroupBox("Competitive preflight") {
            if let report = model.preflight {
                VStack(alignment: .leading, spacing: 10) {
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
