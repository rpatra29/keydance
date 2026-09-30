import Foundation
import Combine
import SwiftData

enum DataRetention: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .oneYear: return "1 year"
        case .forever: return "Forever"
        }
    }

    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .oneYear: return 365
        case .forever: return nil
        }
    }

    var rank: Int { days ?? Int.max }
}

struct HistoricalMetricPoint: Identifiable, Equatable {
    let day: Date
    let wpm: Double
    let accuracy: Double
    let sessionCount: Int

    var id: Date { day }
}

struct CorrectionProfile {
    let backspaces: Int
    let spellingErrors: Int
    let contextualErrors: Int
    let averageEditDistance: Double

    var totalCorrections: Int { backspaces + spellingErrors + contextualErrors }
}

@MainActor
final class AnalyticsStore: ObservableObject {
    nonisolated static let defaultDetailLimit = 1_000
    let container: ModelContainer
    private let context: ModelContext
    private let detailLimit: Int
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var rollups: [DailyRollup] = []
    @Published private(set) var keyAggregates: [DailyKeyAggregate] = []
    @Published private(set) var historicalPoints: [HistoricalMetricPoint] = []

    var correctionProfile: CorrectionProfile {
        let sessionBackspaces = sessions.reduce(0) { $0 + $1.deletionCount }
        let sessionSpelling = sessions.reduce(0) { $0 + $1.spellingErrorWords }
        let sessionContext = sessions.reduce(0) { $0 + $1.contextErrorWords }
        let sessionDistance = sessions.reduce(0) {
            $0 + $1.spellingErrorCharacters + $1.grammarErrorCharacters
        }

        let rollupBackspaces = rollups.reduce(0) { $0 + $1.deletionTotal }
        let rollupSpelling = rollups.reduce(0) { $0 + $1.spellingErrorWordsTotal }
        let rollupContext = rollups.reduce(0) { $0 + $1.contextErrorWordsTotal }
        let rollupDistance = rollups.reduce(0) {
            $0 + $1.spellingErrorCharactersTotal + $1.contextErrorCharactersTotal
        }
        let affectedWords = sessionSpelling + sessionContext + rollupSpelling + rollupContext
        let averageDistance = affectedWords > 0
            ? Double(sessionDistance + rollupDistance) / Double(affectedWords)
            : 0

        return CorrectionProfile(
            backspaces: sessionBackspaces + rollupBackspaces,
            spellingErrors: sessionSpelling + rollupSpelling,
            contextualErrors: sessionContext + rollupContext,
            averageEditDistance: averageDistance
        )
    }

    init(inMemory: Bool = false, detailLimit: Int = AnalyticsStore.defaultDetailLimit) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: SessionRecord.self, DailyRollup.self, DailyKeyAggregate.self, configurations: configuration)
        context = ModelContext(container)
        self.detailLimit = detailLimit
        try refresh()
    }

    func save(_ summary: SessionSummary) throws {
        let record = SessionRecord(summary: summary)
        context.insert(record)
        try mergeDailyStats(for: summary)
        try context.save()
        try downsampleIfNeeded()
        try refresh()
    }

    private func mergeDailyStats(for summary: SessionSummary) throws {
        let day = AnalyticsMath.localDay(for: summary.endedAt)
        let keyDescriptor = FetchDescriptor<DailyKeyAggregate>(predicate: #Predicate { $0.day == day })
        let aggregate = try context.fetch(keyDescriptor).first ?? DailyKeyAggregate(day: day)
        if aggregate.modelContext == nil { context.insert(aggregate) }
        aggregate.merge(keyStats: summary.keyStats, confusions: summary.confusions)
    }

    func refresh() throws {
        var sessionDescriptor = FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.endedAt, order: .reverse)])
        sessionDescriptor.fetchLimit = detailLimit
        sessions = try context.fetch(sessionDescriptor)
        rollups = try context.fetch(FetchDescriptor<DailyRollup>(sortBy: [SortDescriptor(\.day)]))
        keyAggregates = try context.fetch(FetchDescriptor<DailyKeyAggregate>(sortBy: [SortDescriptor(\.day)]))
        historicalPoints = makeHistoricalPoints()
    }

    func applyRetention(_ retention: DataRetention) throws {
        guard let days = retention.days else {
            try refresh()
            return
        }

        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: .now) else { return }
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let records = try context.fetch(FetchDescriptor<SessionRecord>())
        let dailyRollups = try context.fetch(FetchDescriptor<DailyRollup>())
        let dailyKeys = try context.fetch(FetchDescriptor<DailyKeyAggregate>())

        for record in records where record.endedAt < cutoff { context.delete(record) }
        for rollup in dailyRollups where rollup.day < cutoffDay { context.delete(rollup) }
        for aggregate in dailyKeys where aggregate.day < cutoffDay { context.delete(aggregate) }
        try context.save()
        try refresh()
    }

    private func downsampleIfNeeded() throws {
        let all = try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.endedAt, order: .reverse)]))
        guard all.count > detailLimit else { return }
        try context.transaction {
            for record in all.dropFirst(detailLimit) {
                let day = AnalyticsMath.localDay(for: record.endedAt)
                let descriptor = FetchDescriptor<DailyRollup>(predicate: #Predicate { $0.day == day })
                let rollup = try context.fetch(descriptor).first ?? DailyRollup(day: day)
                if rollup.modelContext == nil { context.insert(rollup) }
                rollup.merge(record)
            }
            for record in all.dropFirst(detailLimit) { context.delete(record) }
            try context.save()
        }
    }

    func clearAll() throws {
        try context.delete(model: SessionRecord.self)
        try context.delete(model: DailyRollup.self)
        try context.delete(model: DailyKeyAggregate.self)
        try context.save()
        try refresh()
    }

    private struct HistoryBucket {
        var focusedWPMSum = 0.0
        var accuracySum = 0.0
        var sampleCount = 0

        mutating func add(
            focusedWPM: Double,
            accuracy: Double,
            samples: Int
        ) {
            let count = max(0, samples)
            guard count > 0, focusedWPM.isFinite, accuracy.isFinite else { return }
            focusedWPMSum += max(0, focusedWPM) * Double(count)
            accuracySum += min(1, max(0, accuracy)) * Double(count)
            sampleCount += count
        }

        var pointMetrics: (wpm: Double, accuracy: Double)? {
            guard sampleCount > 0 else { return nil }
            // Each historical point is a daily average of focused-session
            // speed and accuracy. Insights compare the newest day with the
            // previous recorded day, rather than comparing against live WPM.
            return (
                focusedWPMSum / Double(sampleCount),
                accuracySum / Double(sampleCount)
            )
        }
    }

    private func makeHistoricalPoints() -> [HistoricalMetricPoint] {
        var buckets: [Date: HistoryBucket] = [:]

        for rollup in rollups {
            let duration = rollup.activeDuration > 0 ? rollup.activeDuration : rollup.elapsedDuration
            guard rollup.characterTotal > 0, duration > 0 else { continue }
            let focusedWPM = Double(rollup.characterTotal) / 5 / (duration / 60)
            buckets[rollup.day, default: HistoryBucket()].add(
                focusedWPM: focusedWPM,
                accuracy: rollup.estimatedAccuracy,
                samples: max(1, rollup.sessionCount)
            )
        }

        for record in sessions {
            // Trend speed should describe typing pace, not time spent paused
            // between bursts. Older records may not have activeDuration yet,
            // so retain elapsed time as a compatibility fallback.
            let elapsedDuration = record.endedAt.timeIntervalSince(record.startedAt)
            let duration = record.activeDuration > 0 ? record.activeDuration : elapsedDuration
            let characters = record.accuracyCharacterCount > 0
                ? record.accuracyCharacterCount
                : max(record.printableCount, Int((record.wpm * 5 * duration / 60).rounded()))
            let errors = record.accuracyCharacterCount > 0
                ? record.backspaceErrorCharacters + record.spellingErrorCharacters + record.grammarErrorCharacters
                : Int(((1 - record.accuracy) * Double(characters)).rounded())
            let recordAccuracy = record.accuracyCharacterCount > 0
                ? max(0, 1 - Double(errors) / Double(max(characters, 1)))
                : record.accuracy
            let focusedWPM = record.activeWPM > 0
                ? record.activeWPM
                : Double(characters) / 5 / (duration / 60)
            let day = AnalyticsMath.localDay(for: record.endedAt)
            buckets[day, default: HistoryBucket()].add(
                focusedWPM: focusedWPM,
                accuracy: recordAccuracy,
                samples: 1
            )
        }

        return buckets.keys.sorted().compactMap { day in
            guard let bucket = buckets[day], let metrics = bucket.pointMetrics else { return nil }
            return HistoricalMetricPoint(
                day: day,
                wpm: metrics.wpm,
                accuracy: metrics.accuracy,
                sessionCount: bucket.sampleCount
            )
        }
    }
}
