import Foundation
import Combine
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let freshCollectionResetKey = "analyticsFreshCollectionResetV1"

    @Published var trackerState: TrackerState = .paused
    @Published var onboardingComplete: Bool {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    @Published var trackingEnabled: Bool {
        didSet { UserDefaults.standard.set(trackingEnabled, forKey: "trackingEnabled") }
    }
    @Published private(set) var dataRetention: DataRetention
    @Published private(set) var whitelistedWords: Set<String>
    @Published var launchAtLogin = false
    @Published var lastError: String?
    @Published private(set) var permissionGranted = false
    @Published private(set) var eventTapActive = false
    @Published private(set) var lastSavedSessionAt: Date?
    @Published private(set) var liveSession = LiveSessionSnapshot.idle()

    let store: AnalyticsStore
    let vocabulary: [VocabularyEntry]
    private var processor: TrackingProcessor!
    private var monitor: EventTapMonitor!
    private var healthTimer: AnyCancellable?
    private var storeChangeCancellable: AnyCancellable?

    init() {
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        trackingEnabled = UserDefaults.standard.object(forKey: "trackingEnabled") as? Bool ?? true
        // Preserve existing history until the user explicitly chooses an
        // expiration window in Settings.
        dataRetention = DataRetention(rawValue: UserDefaults.standard.string(forKey: "dataRetention") ?? "") ?? .forever
        whitelistedWords = WordWhitelist.words
        vocabulary = Vocabulary.load()
        do {
            store = try AnalyticsStore()
            if !UserDefaults.standard.bool(forKey: Self.freshCollectionResetKey) {
                // The first build with the new analytics model starts a clean
                // local history. Future launches retain only newly collected data.
                try store.clearAll()
                UserDefaults.standard.set(true, forKey: Self.freshCollectionResetKey)
            }
            try store.applyRetention(dataRetention)
        } catch {
            fatalError("Unable to create local analytics store: \(error)")
        }
        storeChangeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        processor = TrackingProcessor(
            vocabulary: vocabulary,
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
        else {
            trackerState = .permissionRequired
            openInputMonitoringSettings()
        }
        permissionGranted = monitor.hasPermission
        eventTapActive = monitor.isRunning
    }

    func completeOnboarding() {
        onboardingComplete = true
    }

    func replayOnboarding() {
        onboardingComplete = false
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

    func updateDataRetention(_ retention: DataRetention) {
        let previous = dataRetention
        dataRetention = retention
        UserDefaults.standard.set(retention.rawValue, forKey: "dataRetention")
        do {
            try store.applyRetention(retention)
        } catch {
            dataRetention = previous
            UserDefaults.standard.set(previous.rawValue, forKey: "dataRetention")
            lastError = "Could not update data retention: \(error.localizedDescription)"
        }
    }

    func whitelistWord(_ word: String) {
        WordWhitelist.add(word)
        whitelistedWords = WordWhitelist.words
    }

    func removeWhitelistedWord(_ word: String) {
        WordWhitelist.remove(word)
        whitelistedWords = WordWhitelist.words
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
    static func load() -> [VocabularyEntry] {
        guard let url = resourceURL(named: "frequency_dictionary_en_82_765", extension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return fallback }

        let entries = contents.split(whereSeparator: \.isNewline).compactMap { line -> VocabularyEntry? in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2,
                  let frequency = Int(columns[1]) else { return nil }
            let word = String(columns[0]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            return VocabularyEntry(word: word, frequency: frequency)
        }
        return entries.isEmpty ? fallback : entries
    }

    static let fallback = [
        "about", "after", "again", "could", "every", "first", "great", "house",
        "other", "people", "right", "small", "their", "there", "these", "thing",
        "think", "through", "under", "water", "where", "which", "world", "would", "write"
    ].enumerated().map { index, word in
        VocabularyEntry(word: word, frequency: 1_000 - index)
    }

    private static func resourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}
