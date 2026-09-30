import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    let showsHeader: Bool
    @State private var confirmingClear = false

    init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Settings")
                            .font(.system(size: 28, weight: .regular, design: .rounded))
                            .foregroundStyle(DashboardTheme.text)
                        Text("Shape how Keydance tracks and keeps your data.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }

                settingsSection("Tracking") {
                    settingsRow(title: "Track typing", detail: "Observe timing while Keydance is running") {
                        Toggle("", isOn: Binding(get: { state.trackingEnabled }, set: { _ in state.toggleTracking() }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsDivider()
                    settingsRow(title: "Status", detail: nil) {
                        Text(state.trackerState.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(state.trackerState == .permissionRequired ? DashboardTheme.orange : DashboardTheme.mint)
                    }
                    if state.trackerState == .permissionRequired {
                        settingsDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Request Input Monitoring permission") { state.requestPermission() }
                            Button("Open Privacy & Security settings") { state.openInputMonitoringSettings() }
                        }
                        .buttonStyle(.bordered)
                        .tint(DashboardTheme.blue)
                        .padding(.vertical, 10)
                    }
                    settingsDivider()
                    settingsRow(title: "Launch at login", detail: "Start quietly with macOS") {
                        Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: state.updateLaunchAtLogin))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                settingsSection("Session model") {
                    settingsRow(title: "Contextual accuracy", detail: "Spelling and intent checks") {
                        Text(ContextualAccuracyScorer.shared.isLoaded ? "Loaded" : "Unavailable")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(ContextualAccuracyScorer.shared.isLoaded ? DashboardTheme.mint : DashboardTheme.orange)
                    }
                    settingsDivider()
                    settingsRow(title: "Session behavior", detail: "Timing and pause interpretation") {
                        Text(state.liveSession.hmm.inferenceBackend)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DashboardTheme.secondary)
                    }
                    settingsDivider()
                    Text("The contextual scorer runs locally from bundled transformer weights. Keydance never stores typed text or app identity.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(DashboardTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }

                settingsSection("Privacy") {
                    Text("Keydance stores statistical summaries only. It never persists typed words, sentences, application names, window titles, clipboard contents, or an ordered key history.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(DashboardTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                    settingsDivider()
                    Text("Historical charts use local daily summaries. No typed text is used to build them.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(DashboardTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                    settingsDivider()
                    settingsRow(title: "Keep history for", detail: "Older data is permanently removed") {
                        Picker("", selection: retentionBinding) {
                            ForEach(DataRetention.allCases) { retention in
                                Text(retention.title).tag(retention)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    settingsDivider()
                    HStack {
                        Button("Purge stored analytics", role: .destructive) { confirmingClear = true }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .background(DashboardBackground())
        .confirmationDialog("Delete older history?", isPresented: Binding(
            get: { pendingRetention != nil },
            set: { if !$0 { pendingRetention = nil } }
        ), titleVisibility: .visible) {
            Button("Delete older data", role: .destructive) {
                if let pendingRetention {
                    state.updateDataRetention(pendingRetention)
                }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("Anything outside the selected retention window will be permanently deleted from this Mac and cannot be recovered.")
        }
        .confirmationDialog("Purge stored analytics?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Purge all stored data", role: .destructive) { state.clearData() }
        } message: { Text("This removes legacy session history, daily rollups, and keyboard aggregates. This cannot be undone.") }
    }

    @State private var pendingRetention: DataRetention?

    private var retentionBinding: Binding<DataRetention> {
        Binding(
            get: { state.dataRetention },
            set: { value in
                if value.rank < state.dataRetention.rank {
                    pendingRetention = value
                } else {
                    state.updateDataRetention(value)
                }
            }
        )
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .background(DashboardTheme.panel.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(DashboardTheme.divider, lineWidth: 1)
            }
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DashboardTheme.muted)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
    }

    private func settingsDivider() -> some View {
        Rectangle()
            .fill(DashboardTheme.divider)
            .frame(height: 1)
    }
}
