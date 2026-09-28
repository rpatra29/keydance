import Foundation
import SwiftData

@Model
final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var startedAt: Date
    var endedAt: Date
    var printableCount: Int
    var correctCount: Int
    var incorrectCount: Int
    var deletionCount: Int
    var correctedErrors: Int
    var uncorrectedEstimate: Int
    var coveredCharacters: Int
    var activeDuration: TimeInterval
    var midPauseCount: Int
    var midPauseTotal: TimeInterval
    var midPauseMedian: TimeInterval
    var betweenPauseCount: Int
    var betweenPauseTotal: TimeInterval
    var betweenPauseMedian: TimeInterval
    var wpm: Double
    var cpm: Double
    var accuracy: Double
    var coverage: Double
    var correctionRate: Double
    var activeWPM: Double = 0
    var rhythmVariation: Double = 0
    var hmmModelVersion: Int = 0
    var modelBackend: String = "Legacy"
    var writingDuration: TimeInterval = 0
    var thinkingDuration: TimeInterval = 0
    var otherActivityDuration: TimeInterval = 0
    var inactiveDuration: TimeInterval = 0
    var featureFrameCount: Int = 0
    var featureFramesData: Data = Data()
    var accuracyCharacterCount: Int = 0
    var backspaceErrorCharacters: Int = 0
    var spellingErrorCharacters: Int = 0
    var grammarErrorCharacters: Int = 0
    var accuracySampleCount: Int = 0

    init(summary: SessionSummary) {
        id = UUID(); kindRaw = summary.kind.rawValue; startedAt = summary.startedAt; endedAt = summary.endedAt
        printableCount = summary.printableCount; correctCount = summary.correctCount; incorrectCount = summary.incorrectCount
        deletionCount = summary.deletionCount; correctedErrors = summary.correctedErrors
        uncorrectedEstimate = summary.uncorrectedEstimate; coveredCharacters = summary.coveredCharacters
        activeDuration = summary.activeDuration
        midPauseCount = summary.midSentencePauses.count; midPauseTotal = summary.midSentencePauses.reduce(0, +)
        midPauseMedian = AnalyticsMath.median(summary.midSentencePauses)
        betweenPauseCount = summary.betweenSentencePauses.count
        betweenPauseTotal = summary.betweenSentencePauses.reduce(0, +)
        betweenPauseMedian = AnalyticsMath.median(summary.betweenSentencePauses)
        wpm = summary.wordsPerMinute; cpm = summary.charactersPerMinute
        accuracy = summary.accuracy; coverage = summary.coverage; correctionRate = summary.correctionRate
        activeWPM = summary.activeWordsPerMinute; rhythmVariation = summary.rhythmVariation
        hmmModelVersion = summary.hmmModelVersion
        modelBackend = summary.modelBackend
        writingDuration = summary.writingDuration; thinkingDuration = summary.thinkingDuration
        otherActivityDuration = summary.otherActivityDuration; inactiveDuration = summary.inactiveDuration
        featureFrameCount = summary.observationWindows.count
        featureFramesData = (try? JSONEncoder().encode(summary.observationWindows)) ?? Data()
        accuracyCharacterCount = summary.accuracyTotals.characterCount
        backspaceErrorCharacters = summary.accuracyTotals.backspaceErrorCharacters
        spellingErrorCharacters = summary.accuracyTotals.spellingErrorCharacters
        grammarErrorCharacters = summary.accuracyTotals.contextErrorCharacters
        accuracySampleCount = summary.accuracyTotals.sentenceCount
    }

    var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .passive }
    var observationWindows: [SessionWindowObservation] {
        (try? JSONDecoder().decode([SessionWindowObservation].self, from: featureFramesData)) ?? []
    }
}

@Model
final class DailyRollup {
    @Attribute(.unique) var day: Date
    var sessionCount: Int
    var benchmarkCount: Int
    var characterTotal: Int
    var correctTotal: Int
    var errorTotal: Int
    var deletionTotal: Int
    var coveredTotal: Int
    var activeDuration: TimeInterval
    var elapsedDuration: TimeInterval
    var midPauseCount: Int
    var midPauseDuration: TimeInterval
    var betweenPauseCount: Int
    var betweenPauseDuration: TimeInterval

    init(day: Date) {
        self.day = day; sessionCount = 0; benchmarkCount = 0; characterTotal = 0; correctTotal = 0
        errorTotal = 0; deletionTotal = 0; coveredTotal = 0; activeDuration = 0; elapsedDuration = 0
        midPauseCount = 0; midPauseDuration = 0; betweenPauseCount = 0; betweenPauseDuration = 0
    }

    func merge(_ record: SessionRecord) {
        sessionCount += 1
        if record.kind == .benchmark { benchmarkCount += 1 }
        let accuracyCharacters = record.accuracyCharacterCount > 0 ? record.accuracyCharacterCount : record.coveredCharacters
        let accuracyErrors = record.accuracyCharacterCount > 0
            ? record.backspaceErrorCharacters + record.spellingErrorCharacters + record.grammarErrorCharacters
            : record.correctedErrors + record.uncorrectedEstimate + record.incorrectCount
        characterTotal += accuracyCharacters
        correctTotal += max(0, accuracyCharacters - accuracyErrors)
        errorTotal += accuracyErrors
        deletionTotal += record.deletionCount; coveredTotal += accuracyCharacters
        activeDuration += record.activeDuration; elapsedDuration += record.endedAt.timeIntervalSince(record.startedAt)
        midPauseCount += record.midPauseCount; midPauseDuration += record.midPauseTotal
        betweenPauseCount += record.betweenPauseCount; betweenPauseDuration += record.betweenPauseTotal
    }

    var wordsPerMinute: Double { elapsedDuration > 0 ? Double(characterTotal) / 5 / (elapsedDuration / 60) : 0 }
    var estimatedAccuracy: Double { coveredTotal > 0 ? max(0, 1 - Double(errorTotal) / Double(coveredTotal)) : 0 }
}

@Model
final class DailyKeyAggregate {
    @Attribute(.unique) var day: Date
    var keyStatsData: Data
    var confusionsData: Data

    init(day: Date) {
        self.day = day; keyStatsData = Data(); confusionsData = Data()
    }

    var keyStats: [KeyAggregate] {
        get { (try? JSONDecoder().decode([KeyAggregate].self, from: keyStatsData)) ?? [] }
        set { keyStatsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var confusions: [ConfusionAggregate] {
        get { (try? JSONDecoder().decode([ConfusionAggregate].self, from: confusionsData)) ?? [] }
        set { confusionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    func merge(keyStats incomingKeys: [KeyAggregate], confusions incomingConfusions: [ConfusionAggregate]) {
        var keys = Dictionary(uniqueKeysWithValues: keyStats.map { ($0.key, $0) })
        for item in incomingKeys {
            keys[item.key, default: KeyAggregate(key: item.key)].activity += item.activity
            keys[item.key, default: KeyAggregate(key: item.key)].corrected += item.corrected
        }
        keyStats = Array(keys.values)

        var pairs = Dictionary(uniqueKeysWithValues: confusions.map { ("\($0.from)>\($0.to)", $0) })
        for item in incomingConfusions {
            let id = "\(item.from)>\(item.to)"
            pairs[id, default: ConfusionAggregate(from: item.from, to: item.to)].count += item.count
        }
        confusions = Array(pairs.values)
    }
}
