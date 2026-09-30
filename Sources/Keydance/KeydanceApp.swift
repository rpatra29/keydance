import SwiftUI

@MainActor
final class KeydanceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct KeydanceApp: App {
    @NSApplicationDelegateAdaptor(KeydanceApplicationDelegate.self) private var applicationDelegate
    @StateObject private var state: AppState

    init() {
        let initialState = AppState()
        _state = StateObject(wrappedValue: initialState)
        initialState.startIfEnabled()
    }

    var body: some Scene {
        Window("Keydance", id: "dashboard") {
                RootView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 680)
                .alert("Keydance", isPresented: Binding(
                    get: { state.lastError != nil },
                    set: { if !$0 { state.lastError = nil } }
                )) { Button("OK") { state.lastError = nil } } message: { Text(state.lastError ?? "") }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Close dashboard") {
                    let window = NSApplication.shared.keyWindow
                        ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                    window?.close()
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Keydance", systemImage: state.trackingEnabled ? "keyboard.badge.ellipsis" : "pause.circle") {
            MenuBarView()
                .environmentObject(state)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSection: WorkspaceSection = .dashboard

    var body: some View {
        ZStack {
            DashboardTheme.background
                .ignoresSafeArea()

            Group {
                if state.onboardingComplete {
                    WorkspaceView(selection: $selectedSection)
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.onboardingComplete)
        .preferredColorScheme(.dark)
    }
}

private struct TopWindowFade: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    colors: [.black, .black.opacity(0.72), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 118)
    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case dashboard
    case insights
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .insights: return "Typing insights"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "rectangle.3.group"
        case .insights: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        }
    }
}

private struct WorkspaceView: View {
    @Binding var selection: WorkspaceSection
    @State private var navigationExpanded = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch selection {
                case .dashboard:
                    DashboardView { selection = .insights }
                case .insights:
                    TypingInsightsView()
                case .settings:
                    SettingsView()
                        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .leading)
                        .padding(36)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 62)

            TopWindowFade()
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .zIndex(1)

            WorkspaceNavigation(selection: $selection, isExpanded: $navigationExpanded)
                .padding(.leading, 18)
                .padding(.top, 18)
                .zIndex(2)

            HStack(spacing: 8) {
                Text("keydance")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
                DashboardLogo(width: 44)
            }
                .padding(.trailing, 26)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .zIndex(2)
        }
        .background(DashboardTheme.background)
    }
}

private struct WorkspaceNavigation: View {
    @Binding var selection: WorkspaceSection
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 3) {
            if isExpanded {
                navigationOption(.dashboard, symbol: "rectangle.3.group")
                navigationOption(.insights, symbol: "waveform.path.ecg")
                navigationOption(.settings, symbol: "gearshape.fill")
            }

            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.left" : sectionSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                    .frame(width: 36, height: 30)
                    .background(DashboardTheme.blue.opacity(isExpanded ? 0.12 : 0.24), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse navigation" : "Expand navigation")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(DashboardTheme.panel.opacity(0.72), in: Capsule())
        .overlay { Capsule().strokeBorder(DashboardTheme.divider, lineWidth: 1) }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
    }

    private var sectionSymbol: String {
        switch selection {
        case .dashboard: return "rectangle.3.group"
        case .insights: return "waveform.path.ecg"
        case .settings: return "gearshape.fill"
        }
    }

    private func navigationOption(
        _ section: WorkspaceSection,
        symbol: String
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selection = section
                isExpanded = false
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selection == section ? DashboardTheme.text : DashboardTheme.secondary)
                .frame(width: 36, height: 30)
                .background(selection == section ? DashboardTheme.blue.opacity(0.24) : .clear, in: Capsule())
                .overlay {
                    if selection == section {
                        Capsule().strokeBorder(DashboardTheme.blue.opacity(0.7), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        menuContent
        .frame(width: 340)
        .padding(18)
        .preferredColorScheme(.dark)
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DashboardTheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("keydance")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(DashboardTheme.text)
                    Text(state.trackingEnabled ? "Tracking quietly" : "Tracking paused")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(DashboardTheme.muted)
                }
                Spacer()
                Circle()
                    .fill(state.trackingEnabled ? DashboardTheme.mint : DashboardTheme.orange)
                    .frame(width: 8, height: 8)
            }

            HStack(spacing: 10) {
                menuMetric("WPM", value: menuSpeed(state.liveSession.accuracyAdjustedWordsPerMinute))
                menuMetric("Accuracy", value: menuAccuracy)
            }

            if state.trackerState == .permissionRequired {
                Button("Grant Input Monitoring…") { state.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .tint(DashboardTheme.blue)
            }

            HStack(spacing: 10) {
                Button(state.trackingEnabled ? "Pause" : "Resume") { state.toggleTracking() }
                    .buttonStyle(.bordered)
                    .tint(DashboardTheme.text)
            }

            Divider().overlay(DashboardTheme.divider)

            Button("Open dashboard") {
                openDashboard()
            }
            .buttonStyle(.plain)
            .foregroundStyle(DashboardTheme.text)

            Button("Replay onboarding") {
                state.replayOnboarding()
                openDashboard()
            }
            .buttonStyle(.plain)
            .foregroundStyle(DashboardTheme.muted)

            Button("Quit Keydance") {
                NSApplication.shared.terminate(nil)
            }
                .buttonStyle(.plain)
                .foregroundStyle(DashboardTheme.orange)
        }
    }

    private func openDashboard() {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func menuMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(DashboardTheme.muted)
            Text(value)
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DashboardTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(DashboardTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var menuAccuracy: String {
        guard state.liveSession.printableCount > 0 else { return "—" }
        return String(format: "%.1f%%", state.liveSession.liveAccuracy * 100)
    }

    private func menuSpeed(_ value: Double) -> String {
        guard state.liveSession.printableCount > 0, value > 0 else { return "—" }
        return String(format: "%.1f", value)
    }
}
