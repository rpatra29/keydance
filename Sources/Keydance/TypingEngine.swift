import Foundation

enum TypingInput: Sendable {
    case printable(Character, keyLabel: String, isRepeat: Bool = false, at: Date)
    case deletion(at: Date)
    case boundary(Character, at: Date)
    case shortcut(at: Date)
    case navigation(at: Date)
    case pointerMovement(distance: Double, eventCount: Int, at: Date)
    case click(at: Date)
    case scroll(distance: Double, at: Date)
}

struct TypingEngine {
    private let estimator: AccuracyEstimating
    private let pauseClassifier: PauseClassifying
    private var stateTracker = TemporalSessionTracker()
    private var writingContext = WritingContextBuffer()
    private var accuracy: SentenceAccuracyAccumulator

    private(set) var startedAt: Date?
    private(set) var lastInputAt: Date?
    private(set) var currentToken = ""
    private var lastTypingInputAt: Date?
    private var lastCharacter: Character?
    private var deletedCharacter: Character?
    private var recentIntervals: [TimeInterval] = []
    private var printableCount = 0
    private var boundaryCount = 0
    private var deletionCount = 0
    private var correctedErrors = 0
    private var uncorrectedEstimate = 0
    private var coveredCharacters = 0
    private var activeDuration: TimeInterval = 0
    private var timedWritingDuration: TimeInterval = 0
    private var timingPaused = false
    private var midSentencePauses: [TimeInterval] = []
    private var betweenSentencePauses: [TimeInterval] = []
    private var keyStats: [String: KeyAggregate] = [:]
    private var confusions: [String: ConfusionAggregate] = [:]

    init(estimator: AccuracyEstimating, pauseClassifier: PauseClassifying = AdaptivePauseClassifier()) {
        self.estimator = estimator
        self.pauseClassifier = pauseClassifier
        self.accuracy = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
    }

    mutating func consume(_ input: TypingInput) -> SessionSummary? {
        let date: Date
        switch input {
        case let .printable(_, _, _, at), let .deletion(at), let .boundary(_, at), let .shortcut(at), let .navigation(at),
             let .pointerMovement(_, _, at), let .click(at), let .scroll(_, at): date = at
        }
        if let summary = advance(to: date) {
            consumeWithoutRollover(input)
            return summary
        }
        consumeWithoutRollover(input)
        return nil
    }

    private mutating func consumeWithoutRollover(_ input: TypingInput) {
        let date: Date
        switch input {
        case let .printable(_, _, _, at), let .deletion(at), let .boundary(_, at), let .shortcut(at), let .navigation(at),
             let .pointerMovement(_, _, at), let .click(at), let .scroll(_, at): date = at
        }
        let isTypingInput: Bool
        switch input {
        case .printable, .deletion, .boundary: isTypingInput = true
        default: isTypingInput = false
        }
        if isTypingInput {
            if let previous = lastTypingInputAt {
                let interval = date.timeIntervalSince(previous)
                if let pause = pauseClassifier.classify(duration: interval, recentIntervals: recentIntervals, previousCharacter: lastCharacter) {
                    writingContext.recordTimingBreak(at: previous)
                    switch pause {
                    case .midSentence: midSentencePauses.append(interval)
                    case .betweenSentence: betweenSentencePauses.append(interval)
                    }
                } else if interval > 0, !timingPaused {
                    activeDuration += min(interval, 2)
                    timedWritingDuration += interval
                }
                if interval > 0, interval < 5 { recentIntervals.append(interval) }
                if recentIntervals.count > 30 { recentIntervals.removeFirst() }
            }
            timingPaused = false
            lastTypingInputAt = date
        } else if startedAt != nil {
            // Explicit non-writing activity freezes the timing accumulator. It
            // does not erase context; later typing may resume the same sentence
            // without charging this gap to its WPM.
            timingPaused = true
            if let lastTypingInputAt { writingContext.recordTimingBreak(at: lastTypingInputAt) }
        }

        switch input {
        case let .printable(character, keyLabel, isRepeat, _):
            if startedAt == nil { startedAt = date; stateTracker.start(at: date) }
            stateTracker.record(.printable(isRepeat: isRepeat), at: date)
            writingContext.recordPrintable(character, at: date)
            accuracy.record(character)
            printableCount += 1
            keyStats[keyLabel, default: KeyAggregate(key: keyLabel)].activity += 1
            if let deletedCharacter {
                correctedErrors += 1
                let old = String(deletedCharacter).lowercased()
                let new = String(character).lowercased()
                if old != new {
                    let id = "\(old)>\(new)"
                    confusions[id, default: ConfusionAggregate(from: old, to: new)].count += 1
                }
                keyStats[old, default: KeyAggregate(key: old)].corrected += 1
                self.deletedCharacter = nil
            }
            if character.isLetter { currentToken.append(character.lowercased()) }
            else { finishToken(); currentToken = "" }
            lastCharacter = character
        case .deletion:
            guard startedAt != nil else { break }
            stateTracker.record(.deletion, at: date)
            writingContext.recordDeletion()
            accuracy.recordDeletion()
            deletionCount += 1
            deletedCharacter = currentToken.last ?? lastCharacter
            if !currentToken.isEmpty { currentToken.removeLast() }
            lastCharacter = currentToken.last
        case let .boundary(character, _):
            guard startedAt != nil else { break }
            stateTracker.record(.boundary, at: date)
            writingContext.recordBoundary(character, at: date)
            accuracy.record(character)
            boundaryCount += 1
            finishToken()
            currentToken = ""
            lastCharacter = character
            deletedCharacter = nil
        case .shortcut:
            guard startedAt != nil else { break }
            stateTracker.record(.shortcut, at: date)
        case .navigation:
            guard startedAt != nil else { break }
            stateTracker.record(.navigation, at: date)
        case let .pointerMovement(distance, eventCount, _):
            guard startedAt != nil else { break }
            stateTracker.record(.pointerMovement(distance: distance, eventCount: eventCount), at: date)
        case .click:
            guard startedAt != nil else { break }
            stateTracker.record(.click, at: date)
        case let .scroll(distance, _):
            guard startedAt != nil else { break }
            stateTracker.record(.scroll(distance: distance), at: date)
        }
        if startedAt != nil { lastInputAt = date }
    }

    private mutating func finishToken() {
        guard !currentToken.isEmpty else { return }
        switch estimator.classify(token: currentToken) {
        case .known:
            coveredCharacters += currentToken.count
        case .likelyMisspelling:
            coveredCharacters += currentToken.count
            uncorrectedEstimate += 1
        case .unknown:
            if estimator.isLikelyGibberish(token: currentToken) {
                coveredCharacters += currentToken.count
                uncorrectedEstimate += 1
            }
        }
    }

    mutating func advance(to date: Date = .now) -> SessionSummary? {
        guard startedAt != nil,
              let inferredEnd = stateTracker.advance(to: date, writingContext: writingContext) else { return nil }
        let summary = makeSummary(endingAt: inferredEnd)
        reset()
        return summary
    }

    mutating func finalize(at date: Date = .now) -> SessionSummary? {
        guard startedAt != nil else { return nil }
        let inferredEnd = stateTracker.finish(at: date, writingContext: writingContext)
        return makeSummary(endingAt: inferredEnd ?? date)
    }

    private mutating func makeSummary(endingAt date: Date) -> SessionSummary {
        let startedAt = self.startedAt!
        finishToken()
        accuracy.finishPending()
        let accuracyTotals = accuracy.totals
        return SessionSummary(
            kind: .passive, startedAt: startedAt, endedAt: max(date, startedAt.addingTimeInterval(0.001)),
            printableCount: printableCount, correctCount: 0, incorrectCount: 0,
            deletionCount: deletionCount, correctedErrors: accuracyTotals.backspaceErrorCharacters,
            uncorrectedEstimate: accuracyTotals.spellingErrorCharacters + accuracyTotals.contextErrorCharacters,
            coveredCharacters: coveredCharacters,
            activeDuration: activeDuration, midSentencePauses: midSentencePauses,
            betweenSentencePauses: betweenSentencePauses,
            keyStats: Array(keyStats.values), confusions: Array(confusions.values),
            observationWindows: stateTracker.observations,
            hmmModelVersion: TemporalSessionTracker.modelVersion,
            modelBackend: stateTracker.inferenceBackendName,
            accuracyTotals: accuracyTotals,
            sentenceAccuracySamples: accuracy.samples
        )
    }

    mutating func clearEphemeral() {
        currentToken = ""
        deletedCharacter = nil
        lastCharacter = nil
        accuracy.reset()
        writingContext.reset()
    }

    func diagnosticSnapshot(at date: Date = .now) -> LiveSessionSnapshot {
        let context = writingContext.snapshot(at: date)
        let modelObservations = stateTracker.observations
        let intentionalCharacterCount = modelObservations
            .filter { $0.inferredState == .writing }
            .reduce(0) { $0 + $1.printableCount + $1.boundaryCount }
        let intentionalDuration = modelObservations
            .filter { $0.inferredState == .writing }
            .reduce(0) { $0 + $1.duration }
        let rawCount = printableCount + boundaryCount
        let diagnostics = stateTracker.diagnostics(at: date)
        let accuracyTotals = accuracy.totals
        return LiveSessionSnapshot(
            capturedAt: date,
            sessionStartedAt: startedAt,
            lastInputAt: lastInputAt,
            printableCount: printableCount,
            deletionCount: deletionCount,
            correctedErrorCount: accuracyTotals.backspaceErrorCharacters,
            uncorrectedEstimate: accuracyTotals.spellingErrorCharacters + accuracyTotals.contextErrorCharacters,
            coveredCharacterCount: coveredCharacters,
            activeDuration: activeDuration,
            midSentencePauseCount: midSentencePauses.count,
            betweenSentencePauseCount: betweenSentencePauses.count,
            adaptivePauseThreshold: AnalyticsMath.pauseThreshold(recentIntervals: recentIntervals),
            rawWordsPerMinute: AnalyticsMath.wordsPerMinute(characters: rawCount, duration: timedWritingDuration),
            intentionalWordsPerMinute: AnalyticsMath.wordsPerMinute(characters: intentionalCharacterCount, duration: intentionalDuration),
            intentionalCharacterCount: intentionalCharacterCount,
            intentionalDuration: intentionalDuration,
            timingPaused: timingPaused,
            accuracyTotals: accuracyTotals,
            accuracyTrace: accuracy.trace,
            sentenceAccuracySamples: accuracy.samples,
            sentenceSpeeds: AnalyticsMath.sentenceSpeeds(from: context.sentenceTimings, observations: modelObservations),
            hmm: diagnostics
        )
    }

    mutating func reset() {
        startedAt = nil; lastInputAt = nil; lastTypingInputAt = nil; currentToken = ""; lastCharacter = nil; deletedCharacter = nil
        recentIntervals = []; printableCount = 0; boundaryCount = 0; deletionCount = 0; correctedErrors = 0
        uncorrectedEstimate = 0; coveredCharacters = 0; activeDuration = 0; timedWritingDuration = 0; timingPaused = false
        midSentencePauses = []; betweenSentencePauses = []; keyStats = [:]; confusions = [:]
        accuracy.reset()
        writingContext.reset()
        stateTracker.reset()
    }
}
