import Foundation

enum SessionKind: String, Codable, Sendable {
    case passive
    case benchmark
}

enum PauseKind: Sendable {
    case midSentence
    case betweenSentence
}

struct PauseSample: Sendable {
    let duration: TimeInterval
    let kind: PauseKind
}

/// Numeric speed telemetry for one in-memory sentence. It deliberately does
/// not retain the sentence text or any key identity.
struct SentenceSpeedSample: Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let characterCount: Int
    let rawDuration: TimeInterval
    let intentionalCharacterCount: Int
    let intentionalDuration: TimeInterval
    let isComplete: Bool

    var rawWordsPerMinute: Double {
        AnalyticsMath.wordsPerMinute(characters: characterCount, duration: rawDuration)
    }

    /// Nil means the model has not completed a writing-state window covering
    /// this sentence yet; showing zero would falsely imply a slow typist.
    var intentionalWordsPerMinute: Double? {
        guard intentionalDuration > 0, intentionalCharacterCount > 0 else { return nil }
        return AnalyticsMath.wordsPerMinute(characters: intentionalCharacterCount, duration: intentionalDuration)
    }

    var modelCoverage: Double {
        characterCount > 0 ? Double(intentionalCharacterCount) / Double(characterCount) : 0
    }
}

struct KeyAggregate: Codable, Hashable, Sendable {
    var key: String
    var activity: Int = 0
    var corrected: Int = 0
}

struct ConfusionAggregate: Codable, Hashable, Sendable {
    var from: String
    var to: String
    var count: Int = 0
}

struct SessionSummary: Sendable {
    var kind: SessionKind
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
    var midSentencePauses: [TimeInterval]
    var betweenSentencePauses: [TimeInterval]
    var keyStats: [KeyAggregate]
    var confusions: [ConfusionAggregate]
    var observationWindows: [SessionWindowObservation] = []
    var hmmModelVersion: Int = 0
    var modelBackend: String = "None"
    var accuracyTotals: AccuracyTotals = AccuracyTotals()
    var sentenceAccuracySamples: [SentenceAccuracySample] = []

    var elapsed: TimeInterval { max(endedAt.timeIntervalSince(startedAt), 0.001) }
    /// Passive typing has no reference text, so its Monkeytype-style WPM uses
    /// every measured character, including spaces. Accuracy remains a
    /// separate metric instead of shrinking the displayed typing speed.
    var measuredCharacterCount: Int {
        kind == .benchmark ? correctCount : max(printableCount, accuracyTotals.characterCount)
    }
    var wordsPerMinute: Double { Double(measuredCharacterCount) / 5 / (elapsed / 60) }
    /// Pace across the intentional writing session, including thinking pauses
    /// but ending when the session boundary is inferred or explicitly chosen.
    var writingWordsPerMinute: Double { wordsPerMinute }
    var charactersPerMinute: Double { Double(measuredCharacterCount) / (elapsed / 60) }
    var accuracy: Double {
        if kind == .benchmark {
            return printableCount > 0 ? Double(max(0, printableCount - incorrectCount)) / Double(printableCount) : 1
        }
        return accuracyTotals.accuracy
    }
    var coverage: Double { printableCount > 0 ? Double(coveredCharacters) / Double(printableCount) : 0 }
    var correctionRate: Double { printableCount > 0 ? Double(deletionCount) / Double(printableCount) : 0 }
    var activeWordsPerMinute: Double {
        activeTypingWordsPerMinute
    }
    /// Pace while keys are actively producing/editing text. Ordinary motor
    /// delays remain eligible; substantial pauses are excluded by TypingEngine.
    var activeTypingWordsPerMinute: Double {
        activeDuration > 0 ? Double(printableCount) / 5 / (activeDuration / 60) : 0
    }
    var writingDuration: TimeInterval { stateDuration(.writing) }
    var thinkingDuration: TimeInterval { stateDuration(.thinking) }
    var otherActivityDuration: TimeInterval { stateDuration(.otherActivity) }
    var inactiveDuration: TimeInterval { stateDuration(.inactive) }
    var uncertainDuration: TimeInterval { stateDuration(.uncertain) }
    var rhythmVariation: Double {
        let measured = observationWindows.filter { $0.intervalCount > 1 }
        guard !measured.isEmpty else { return 0 }
        return measured.map(\.rhythmVariation).reduce(0, +) / Double(measured.count)
    }

    private func stateDuration(_ state: TypingBehaviorState) -> TimeInterval {
        observationWindows.filter { $0.inferredState == state }.reduce(0) { $0 + $1.duration }
    }
}

struct LiveSessionSnapshot: Sendable {
    var capturedAt: Date
    var sessionStartedAt: Date?
    var lastInputAt: Date?
    var printableCount: Int
    var deletionCount: Int
    var correctedErrorCount: Int
    var uncorrectedEstimate: Int
    var coveredCharacterCount: Int
    var activeDuration: TimeInterval
    var midSentencePauseCount: Int
    var betweenSentencePauseCount: Int
    var adaptivePauseThreshold: TimeInterval
    var rawWordsPerMinute: Double
    var intentionalWordsPerMinute: Double
    var intentionalCharacterCount: Int
    var intentionalDuration: TimeInterval
    var timingPaused: Bool
    var accuracyTotals: AccuracyTotals
    var accuracyTrace: AccuracyTrace
    var sentenceAccuracySamples: [SentenceAccuracySample]
    var sentenceSpeeds: [SentenceSpeedSample]
    var hmm: TemporalTrackerDiagnostics

    var hasActiveSession: Bool { sessionStartedAt != nil }
    /// Net WPM subtracts deleted characters from the live gross count.
    /// It is a correction-adjusted pace proxy, not reference-text accuracy.
    var netWordsPerMinute: Double {
        guard printableCount > 0 else { return 0 }
        return rawWordsPerMinute * Double(max(0, printableCount - deletionCount)) / Double(printableCount)
    }
    /// Live pace adjusted by the accuracy signal available from the local model.
    var accuracyAdjustedWordsPerMinute: Double {
        rawWordsPerMinute * liveAccuracy
    }
    var liveAccuracy: Double {
        let currentCharacters = accuracyTrace.currentText.reduce(into: 0) { count, character in
            if !character.isWhitespace && !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                count += 1
            }
        }
        let currentSpellingErrors = accuracyTrace.spellingErrorCharacters
        let currentContextErrors = accuracyTrace.contextErrorCharacters
        let measuredCharacters = accuracyTotals.characterCount + currentCharacters
        let measuredErrors = accuracyTotals.errorCharacters
            + accuracyTrace.backspaceErrors
            + currentSpellingErrors
            + currentContextErrors
        guard measuredCharacters > 0 else { return 1 }
        return max(0, 1 - Double(measuredErrors) / Double(measuredCharacters))
    }
    var elapsed: TimeInterval {
        sessionStartedAt.map { max(0, capturedAt.timeIntervalSince($0)) } ?? 0
    }
    var secondsSinceLastInput: TimeInterval? {
        lastInputAt.map { max(0, capturedAt.timeIntervalSince($0)) }
    }

    static func idle(at date: Date = .now) -> LiveSessionSnapshot {
        LiveSessionSnapshot(
            capturedAt: date, sessionStartedAt: nil, lastInputAt: nil,
            printableCount: 0, deletionCount: 0, correctedErrorCount: 0,
            uncorrectedEstimate: 0, coveredCharacterCount: 0, activeDuration: 0,
            midSentencePauseCount: 0, betweenSentencePauseCount: 0,
            adaptivePauseThreshold: 1.2,
            rawWordsPerMinute: 0, intentionalWordsPerMinute: 0,
            intentionalCharacterCount: 0, intentionalDuration: 0,
            timingPaused: false,
            accuracyTotals: AccuracyTotals(),
            accuracyTrace: AccuracyTrace(currentText: "", currentTokens: [], spellingCandidates: [], contextCandidates: [], spellingErrorCharacters: 0, contextErrorCharacters: 0, backspaceErrors: 0, lastSample: nil),
            sentenceAccuracySamples: [],
            sentenceSpeeds: [],
            hmm: TemporalTrackerDiagnostics(
                inferenceBackend: "Text-aware fallback",
                modelStatus: SessionTextModelRuntime.shared.status,
                completedFrameCount: 0, latestState: nil, latestProbabilities: [:],
                latestTextModelProbabilities: [:],
                latestInterpretation: nil,
                latestSentenceState: .uncertain, latestActivityState: .uncertain,
                latestPredictionConfidence: 0, latestPredictionIsProvisional: true,
                currentFrameStartedAt: nil, currentFrameElapsed: 0,
                currentPrintableCount: 0, currentDeletionCount: 0, currentBoundaryCount: 0,
                currentShortcutCount: 0, currentNavigationCount: 0, currentRepeatedKeyCount: 0,
                currentPointerMovementCount: 0, currentPointerDistance: 0,
                currentClickCount: 0, currentScrollCount: 0, currentScrollDistance: 0,
                totalBoundaryCount: 0, totalShortcutCount: 0, totalNavigationCount: 0,
                totalRepeatedKeyCount: 0, totalPointerMovementCount: 0, totalPointerDistance: 0,
                totalClickCount: 0, totalScrollCount: 0, totalScrollDistance: 0,
                secondsSinceTypingEvent: nil,
                consecutiveInactiveFrames: 0, writingDuration: 0, thinkingDuration: 0,
                otherActivityDuration: 0, inactiveDuration: 0, latestObservation: nil
            )
        )
    }
}

enum AnalyticsMath {
    static func wordsPerMinute(characters: Int, duration: TimeInterval) -> Double {
        guard characters > 0, duration > 0 else { return 0 }
        return Double(characters) / 5 / (duration / 60)
    }

    static func sentenceSpeeds(
        from sentences: [WritingContextSnapshot.SentenceTiming],
        observations: [SessionWindowObservation]
    ) -> [SentenceSpeedSample] {
        sentences.enumerated().map { index, sentence in
            let intentionalTimestamps = sentence.characterTimestamps.filter { timestamp in
                observations.contains { observation in
                    let end = observation.startedAt.addingTimeInterval(observation.duration)
                    return observation.inferredState == .writing
                        && timestamp >= observation.startedAt
                        && timestamp < end
                }
            }
            let intentionalDuration = observations.reduce(0) { total, observation in
                guard observation.inferredState == .writing else { return total }
                let start = max(sentence.startedAt, observation.startedAt)
                let end = min(sentence.endedAt, observation.startedAt.addingTimeInterval(observation.duration))
                return total + max(0, end.timeIntervalSince(start))
            }
            return SentenceSpeedSample(
                id: index,
                characterCount: sentence.characterCount,
                rawDuration: sentence.timedDuration,
                intentionalCharacterCount: intentionalTimestamps.count,
                intentionalDuration: intentionalDuration,
                isComplete: sentence.isComplete
            )
        }
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(max(percentile, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    static func pauseThreshold(recentIntervals: [TimeInterval]) -> TimeInterval {
        let baseline = median(Array(recentIntervals.suffix(30)))
        guard baseline > 0 else { return 1.2 }
        return min(3, max(0.8, baseline * 5))
    }

    /// A robust local baseline for provisional boundary decisions. It needs
    /// enough observations before personalizing and is bounded so an unusual
    /// session cannot make the app wait forever.
    static func personalizedPauseThreshold(recentIntervals: [TimeInterval]) -> TimeInterval {
        let usable = recentIntervals.filter { $0 > 0 && $0 <= 10 }
        guard usable.count >= 5 else { return 1.2 }
        let median = self.median(usable)
        let upper = self.percentile(usable, percentile: 0.90)
        return min(8, max(1.2, max(median * 5, upper * 1.5)))
    }

    static func localDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}
