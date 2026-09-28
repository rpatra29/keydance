import Foundation
import Combine
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var trackerState: TrackerState = .paused
    @Published var trackingEnabled: Bool {
        didSet { UserDefaults.standard.set(trackingEnabled, forKey: "trackingEnabled") }
    }
    @Published var launchAtLogin = false
    @Published var lastError: String?
    @Published private(set) var permissionGranted = false
    @Published private(set) var eventTapActive = false
    @Published private(set) var lastSavedSessionAt: Date?
    @Published private(set) var liveSession = LiveSessionSnapshot.idle()

    let store: AnalyticsStore
    let words: [String]
    private var processor: TrackingProcessor!
    private var monitor: EventTapMonitor!
    private var healthTimer: AnyCancellable?

    init() {
        trackingEnabled = UserDefaults.standard.object(forKey: "trackingEnabled") as? Bool ?? true
        words = Vocabulary.load()
        do {
            store = try AnalyticsStore()
        } catch {
            fatalError("Unable to create local analytics store: \(error)")
        }
        processor = TrackingProcessor(
            words: words,
            onSummary: { [weak self] summary in
                Task { @MainActor [weak self] in self?.persist(summary) }
            },
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.receive(snapshot) }
            }
        )
        monitor = EventTapMonitor(processor: processor)
        monitor.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackerState = state
                self.eventTapActive = self.monitor.isRunning
            }
        }
        permissionGranted = monitor.hasPermission
        eventTapActive = monitor.isRunning
        launchAtLogin = SMAppService.mainApp.status == .enabled
        healthTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.checkTrackerHealth()
        }
    }

    func startIfEnabled() {
        guard trackingEnabled else { trackerState = .paused; return }
        monitor.start()
        permissionGranted = monitor.hasPermission
        eventTapActive = monitor.isRunning
    }

    func toggleTracking() {
        trackingEnabled.toggle()
        if trackingEnabled { monitor.start() }
        else { monitor.stop(); trackerState = .paused }
        permissionGranted = monitor.hasPermission
        eventTapActive = monitor.isRunning
    }

    func requestPermission() {
        if monitor.requestPermission() { monitor.start() }
        else { trackerState = .permissionRequired }
        permissionGranted = monitor.hasPermission
        eventTapActive = monitor.isRunning
    }

    func persist(_ summary: SessionSummary) {
        do {
            try store.save(summary)
            lastSavedSessionAt = .now
        }
        catch { lastError = "Could not save analytics: \(error.localizedDescription)" }
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastError = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    func clearData() {
        processor.discardAndClear { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.store.clearAll()
                } catch {
                    self.lastError = "Could not clear analytics: \(error.localizedDescription)"
                }
            }
        }
    }

    func finishCurrentSession() {
        processor.finishAndClear()
    }

    func discardCurrentSession() {
        processor.discardAndClear()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func checkTrackerHealth() {
        permissionGranted = monitor.hasPermission
        if trackingEnabled {
            if permissionGranted, !monitor.isRunning {
                monitor.start()
            } else {
                monitor.checkHealth()
            }
        } else if trackerState != .paused {
            trackerState = .paused
        }
        eventTapActive = monitor.isRunning
    }

    private func receive(_ snapshot: LiveSessionSnapshot) {
        liveSession = snapshot
    }

}

enum Vocabulary {
    static func load() -> [String] {
        guard let url = resourceURL(named: "words", extension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        return contents.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
    }

    static let fallback = ["about", "after", "again", "could", "every", "first", "great", "house", "other", "people", "right", "small", "their", "there", "these", "thing", "think", "through", "under", "water", "where", "which", "world", "would", "write"]

    static func deniedTerms() -> Set<String> {
        guard let url = resourceURL(named: "denied_terms", extension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty })
    }

    private static func resourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}
