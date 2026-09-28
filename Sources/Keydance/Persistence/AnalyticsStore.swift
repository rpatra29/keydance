import Foundation
import Combine
import SwiftData

@MainActor
final class AnalyticsStore: ObservableObject {
    nonisolated static let defaultDetailLimit = 1_000
    let container: ModelContainer
    private let context: ModelContext
    private let detailLimit: Int
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var rollups: [DailyRollup] = []
    @Published private(set) var keyAggregates: [DailyKeyAggregate] = []

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
}
