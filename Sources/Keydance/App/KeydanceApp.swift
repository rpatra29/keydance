import SwiftUI

@main
struct KeydanceApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Keydance", id: "dashboard") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 920, minHeight: 680)
                .task { state.startIfEnabled() }
                .alert("Keydance", isPresented: Binding(
                    get: { state.lastError != nil },
                    set: { if !$0 { state.lastError = nil } }
                )) { Button("OK") { state.lastError = nil } } message: { Text(state.lastError ?? "") }
        }
        .defaultSize(width: 1080, height: 760)

        MenuBarExtra("Keydance", systemImage: state.trackingEnabled ? "keyboard.badge.ellipsis" : "pause.circle") {
            MenuBarView()
                .environmentObject(state)
        }
    }
}

struct RootView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DashboardView().tabItem { Label("Session", systemImage: "waveform.path.ecg") }.tag(0)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(1)
        }
        .padding(18)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.trackerState.title)
        Divider()
        Button(state.trackingEnabled ? "Pause tracking" : "Resume tracking") { state.toggleTracking() }
        if state.trackerState == .permissionRequired { Button("Grant Input Monitoring…") { state.requestPermission() } }
        Button("Finish & save current session") { state.finishCurrentSession() }
        Button("Open Keydance") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
