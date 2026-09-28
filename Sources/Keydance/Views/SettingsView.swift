import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Track typing while Keydance is running", isOn: Binding(get: { state.trackingEnabled }, set: { _ in state.toggleTracking() }))
                LabeledContent("Status", value: state.trackerState.title)
                if state.trackerState == .permissionRequired {
                    Button("Request Input Monitoring permission") { state.requestPermission() }
                    Button("Open Privacy & Security settings") { state.openInputMonitoringSettings() }
                }
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.updateLaunchAtLogin))
            }
            Section("Session model") {
                LabeledContent("Inference", value: state.liveSession.hmm.inferenceBackend)
                Text(state.liveSession.hmm.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The model runs locally on privacy-safe activity features. Keydance never stores typed text or app identity.")
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Keydance stores statistical summaries only. It never persists typed words, sentences, application names, window titles, clipboard contents, or an ordered key history.")
                    .foregroundStyle(.secondary)
                Text("The dashboard shows live session metrics. Stored historical session records are not used there.")
                    .foregroundStyle(.secondary)
                Button("Purge stored analytics", role: .destructive) { confirmingClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Purge stored analytics?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Purge all stored data", role: .destructive) { state.clearData() }
        } message: { Text("This removes legacy session history, daily rollups, and keyboard aggregates. This cannot be undone.") }
    }
}
