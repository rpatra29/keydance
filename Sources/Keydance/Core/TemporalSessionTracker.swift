import Foundation

enum TypingBehaviorState: String, Codable, CaseIterable, Sendable {
    case writing
    case thinking
    case otherActivity
    case inactive
    case uncertain
}

enum SentenceState: String, Codable, CaseIterable, Sendable {
    case incomplete
    case likelyComplete
    case uncertain
}

enum ActivityState: String, Codable, CaseIterable, Sendable {
    case activeTyping
    case thinking
    case finished
    case uncertain
}

enum BehavioralEventKind: Sendable {
    case printable(isRepeat: Bool)
    case deletion
    case boundary
    case shortcut
    case navigation
    case pointerMovement(distance: Double, eventCount: Int)
    case click
    case scroll(distance: Double)
}

/// A privacy-safe feature vector. It contains timing and event categories, never
/// typed characters, key codes, application identity, or an ordered key history.
struct SessionWindowObservation: Codable, Sendable, Equatable {
    var startedAt: Date
    var duration: TimeInterval
    var printableCount: Int
    var deletionCount: Int
    var boundaryCount: Int
    var shortcutCount: Int
    var navigationKeyCount: Int
    var repeatedKeyCount: Int
    var pointerMovementCount: Int
    var pointerDistance: Double
    var clickCount: Int
    var scrollCount: Int
    var scrollDistance: Double
    var intervalCount: Int
    var meanInterKeyInterval: TimeInterval
    var medianInterKeyInterval: TimeInterval
    var tenthPercentileInterKeyInterval: TimeInterval
    var ninetiethPercentileInterKeyInterval: TimeInterval
    var ninetyFifthPercentileInterKeyInterval: TimeInterval
    var interKeyIntervalDeviation: TimeInterval
    var shortestInterKeyInterval: TimeInterval
    var longestInterKeyInterval: TimeInterval
    /// Counts for <50ms, <100ms, <200ms, <500ms, <1s, <2s, and >=2s.
    var interKeyIntervalHistogram: [Int]
    var silenceDurationAtEnd: TimeInterval
    var burstCount: Int
    var inferredState: TypingBehaviorState
    var stateProbabilities: [String: Double]

    var eventCount: Int {
        printableCount + deletionCount + boundaryCount + shortcutCount + navigationKeyCount
            + pointerMovementCount + clickCount + scrollCount
    }
    var eventsPerSecond: Double { duration > 0 ? Double(eventCount) / duration : 0 }
    var printableRatio: Double { eventCount > 0 ? Double(printableCount) / Double(eventCount) : 0 }
    var otherKeyRatio: Double {
        eventCount > 0 ? Double(shortcutCount + navigationKeyCount + pointerMovementCount + clickCount + scrollCount) / Double(eventCount) : 0
    }
    var correctionFrequency: Double {
        printableCount > 0 ? Double(deletionCount) / Double(printableCount) : 0
    }
    var rhythmVariation: Double {
        meanInterKeyInterval > 0 ? interKeyIntervalDeviation / meanInterKeyInterval : 0
    }
}

struct TemporalTrackerDiagnostics: Sendable {
    var inferenceBackend: String
    var modelStatus: String
    var completedFrameCount: Int
    var latestState: TypingBehaviorState?
    var latestProbabilities: [String: Double]
    var latestTextModelProbabilities: [String: Double]
    var latestInterpretation: StackModelInterpretation?
    var latestSentenceState: SentenceState
    var latestActivityState: ActivityState
    var latestPredictionConfidence: Double
    var latestPredictionIsProvisional: Bool
    var currentFrameStartedAt: Date?
    var currentFrameElapsed: TimeInterval
    var currentPrintableCount: Int
    var currentDeletionCount: Int
    var currentBoundaryCount: Int
    var currentShortcutCount: Int
    var currentNavigationCount: Int
    var currentRepeatedKeyCount: Int
    var currentPointerMovementCount: Int
    var currentPointerDistance: Double
    var currentClickCount: Int
    var currentScrollCount: Int
    var currentScrollDistance: Double
    var totalBoundaryCount: Int
    var totalShortcutCount: Int
    var totalNavigationCount: Int
    var totalRepeatedKeyCount: Int
    var totalPointerMovementCount: Int
    var totalPointerDistance: Double
    var totalClickCount: Int
    var totalScrollCount: Int
    var totalScrollDistance: Double
    var secondsSinceTypingEvent: TimeInterval?
    var consecutiveInactiveFrames: Int
    var writingDuration: TimeInterval
    var thinkingDuration: TimeInterval
    var otherActivityDuration: TimeInterval
    var inactiveDuration: TimeInterval
    var latestObservation: SessionWindowObservation?
}

struct TemporalSessionTracker {
    // Bumped when temporal post-processing semantics change. Existing persisted
    // windows remain decodable, but new sessions must be identifiable in metrics.
    static let modelVersion = 3
    static let windowDuration: TimeInterval = 5

    private let textFallback = TextAwareFallbackClassifier()
    private let textModel = SessionTextModelRuntime.shared
    private var inferenceBackend = "Text-aware fallback"
    private var windowStartedAt: Date?
    private var lastEventAt: Date?
    private var lastTypingEventAt: Date?
    private var printableCount = 0
    private var deletionCount = 0
    private var boundaryCount = 0
    private var shortcutCount = 0
    private var navigationKeyCount = 0
    private var repeatedKeyCount = 0
    private var pointerMovementCount = 0
    private var pointerDistance = 0.0
    private var clickCount = 0
    private var scrollCount = 0
    private var scrollDistance = 0.0
    private var intervals: [TimeInterval] = []
    private var consecutiveInactiveWindows = 0
    private var firstInactiveWindowAt: Date?
    private var consecutivePauseWindows = 0
    private var baselineIntervals: [TimeInterval] = []
    private var latestTextModelProbabilities: [String: Double] = [:]
    private var latestInterpretation: StackModelInterpretation?
    private var latestSentenceState: SentenceState = .uncertain
    private var latestActivityState: ActivityState = .uncertain
    private var latestPredictionConfidence = 0.0
    private var latestPredictionIsProvisional = true
    private(set) var observations: [SessionWindowObservation] = []
    var inferenceBackendName: String { inferenceBackend }

    mutating func start(at date: Date) {
        if windowStartedAt == nil { windowStartedAt = date }
    }

    mutating func record(_ kind: BehavioralEventKind, at date: Date) {
        start(at: date)
        if kind.isTyping, let previous = lastTypingEventAt {
            let interval = date.timeIntervalSince(previous)
            if interval > 0, interval <= 120 {
                baselineIntervals.append(interval)
                if baselineIntervals.count > 120 { baselineIntervals.removeFirst() }
            }
            reconcileResumedTyping()
        }
        if let previous = lastEventAt {
            let interval = date.timeIntervalSince(previous)
            if interval > 0 { intervals.append(interval) }
        }
        lastEventAt = date
        switch kind {
        case let .printable(isRepeat):
            printableCount += 1
            if isRepeat { repeatedKeyCount += 1 }
            lastTypingEventAt = date
        case .deletion:
            deletionCount += 1
            lastTypingEventAt = date
        case .boundary:
            boundaryCount += 1
            lastTypingEventAt = date
        case .shortcut:
            shortcutCount += 1
        case .navigation:
            navigationKeyCount += 1
        case let .pointerMovement(distance, eventCount):
            pointerMovementCount += eventCount
            pointerDistance += max(0, distance)
        case .click:
            clickCount += 1
        case let .scroll(distance):
            scrollCount += 1
            scrollDistance += abs(distance)
        }
    }

    /// Advances completed windows and returns the inferred session end after two
    /// consecutive inactive windows. The first inactive window marks the boundary.
    mutating func advance(to date: Date, writingContext: WritingContextBuffer? = nil) -> Date? {
        guard var start = windowStartedAt else { return nil }
        while start.addingTimeInterval(Self.windowDuration) <= date {
            let end = start.addingTimeInterval(Self.windowDuration)
            let observation = inferObservation(start: start, end: end, writingContext: writingContext?.snapshot(at: end))
            observations.append(observation)
            clearWindow(startingAt: end)
            start = end

            if observation.inferredState == .inactive {
                consecutiveInactiveWindows += 1
                if firstInactiveWindowAt == nil { firstInactiveWindowAt = observation.startedAt }
                if consecutiveInactiveWindows >= 2 { return firstInactiveWindowAt }
            } else {
                consecutiveInactiveWindows = 0
                firstInactiveWindowAt = nil
            }
        }
        return nil
    }

    mutating func finish(at date: Date, writingContext: WritingContextBuffer? = nil) -> Date? {
        guard let start = windowStartedAt, date > start else { return nil }
        if let inferredEnd = advance(to: date, writingContext: writingContext) { return inferredEnd }
        guard let currentStart = windowStartedAt, date > currentStart else { return nil }
        observations.append(inferObservation(start: currentStart, end: date, writingContext: writingContext?.snapshot(at: date)))
        clearWindow(startingAt: date)
        return nil
    }

    mutating func reset() { self = TemporalSessionTracker() }

    func diagnostics(at date: Date) -> TemporalTrackerDiagnostics {
        func total(_ keyPath: KeyPath<SessionWindowObservation, Int>, current: Int) -> Int {
            observations.reduce(current) { $0 + $1[keyPath: keyPath] }
        }
        func duration(_ state: TypingBehaviorState) -> TimeInterval {
            observations.filter { $0.inferredState == state }.reduce(0) { $0 + $1.duration }
        }
        let latest = observations.last
        return TemporalTrackerDiagnostics(
            inferenceBackend: inferenceBackend,
            modelStatus: textModel.status,
            completedFrameCount: observations.count,
            latestState: latest?.inferredState,
            latestProbabilities: latest?.stateProbabilities ?? [:],
            latestTextModelProbabilities: latestTextModelProbabilities,
            latestInterpretation: latestInterpretation,
            latestSentenceState: latestSentenceState,
            latestActivityState: latestActivityState,
            latestPredictionConfidence: latestPredictionConfidence,
            latestPredictionIsProvisional: latestPredictionIsProvisional,
            currentFrameStartedAt: windowStartedAt,
            currentFrameElapsed: windowStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0,
            currentPrintableCount: printableCount,
            currentDeletionCount: deletionCount,
            currentBoundaryCount: boundaryCount,
            currentShortcutCount: shortcutCount,
            currentNavigationCount: navigationKeyCount,
            currentRepeatedKeyCount: repeatedKeyCount,
            currentPointerMovementCount: pointerMovementCount,
            currentPointerDistance: pointerDistance,
            currentClickCount: clickCount,
            currentScrollCount: scrollCount,
            currentScrollDistance: scrollDistance,
            totalBoundaryCount: total(\.boundaryCount, current: boundaryCount),
            totalShortcutCount: total(\.shortcutCount, current: shortcutCount),
            totalNavigationCount: total(\.navigationKeyCount, current: navigationKeyCount),
            totalRepeatedKeyCount: total(\.repeatedKeyCount, current: repeatedKeyCount),
            totalPointerMovementCount: total(\.pointerMovementCount, current: pointerMovementCount),
            totalPointerDistance: observations.reduce(pointerDistance) { $0 + $1.pointerDistance },
            totalClickCount: total(\.clickCount, current: clickCount),
            totalScrollCount: total(\.scrollCount, current: scrollCount),
            totalScrollDistance: observations.reduce(scrollDistance) { $0 + $1.scrollDistance },
            secondsSinceTypingEvent: lastTypingEventAt.map { max(0, date.timeIntervalSince($0)) },
            consecutiveInactiveFrames: consecutiveInactiveWindows,
            writingDuration: duration(.writing),
            thinkingDuration: duration(.thinking),
            otherActivityDuration: duration(.otherActivity),
            inactiveDuration: duration(.inactive),
            latestObservation: latest
        )
    }

    private mutating func inferObservation(
        start: Date,
        end: Date,
        writingContext: WritingContextSnapshot?
    ) -> SessionWindowObservation {
        let duration = max(end.timeIntervalSince(start), 0.001)
        let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let deviation: Double
        if intervals.count > 1 {
            let variance = intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)
            deviation = sqrt(variance)
        } else {
            deviation = 0
        }
        let silence = lastTypingEventAt.map { max(0, end.timeIntervalSince($0)) } ?? duration
        let eventCount = printableCount + deletionCount + boundaryCount + shortcutCount + navigationKeyCount
            + pointerMovementCount + clickCount + scrollCount
        let bursts = eventCount == 0 ? 0 : 1 + intervals.filter { $0 >= 2 }.count
        var observation = SessionWindowObservation(
            startedAt: start,
            duration: duration,
            printableCount: printableCount,
            deletionCount: deletionCount,
            boundaryCount: boundaryCount,
            shortcutCount: shortcutCount,
            navigationKeyCount: navigationKeyCount,
            repeatedKeyCount: repeatedKeyCount,
            pointerMovementCount: pointerMovementCount,
            pointerDistance: pointerDistance,
            clickCount: clickCount,
            scrollCount: scrollCount,
            scrollDistance: scrollDistance,
            intervalCount: intervals.count,
            meanInterKeyInterval: mean,
            medianInterKeyInterval: AnalyticsMath.median(intervals),
            tenthPercentileInterKeyInterval: AnalyticsMath.percentile(intervals, percentile: 0.10),
            ninetiethPercentileInterKeyInterval: AnalyticsMath.percentile(intervals, percentile: 0.90),
            ninetyFifthPercentileInterKeyInterval: AnalyticsMath.percentile(intervals, percentile: 0.95),
            interKeyIntervalDeviation: deviation,
            shortestInterKeyInterval: intervals.min() ?? 0,
            longestInterKeyInterval: intervals.max() ?? 0,
            interKeyIntervalHistogram: intervalHistogram(intervals),
            silenceDurationAtEnd: silence,
            burstCount: bursts,
            inferredState: .inactive,
            stateProbabilities: [:]
        )
        let context = writingContext ?? WritingContextSnapshot.empty(at: end)
        let textInput = TextAwareModelInput(frame: observation, context: context)
        let prediction: WritingStatePrediction
        if let modelPrediction = textModel.predict(input: textInput) {
            self.inferenceBackend = "Core ML text model"
            prediction = modelPrediction
        } else {
            let fallback = textFallback.infer(input: textInput)
            self.inferenceBackend = "Text-aware fallback"
            prediction = fallback
        }
        self.latestTextModelProbabilities = prediction.probabilities
        let completion = StackSentenceCompletionClassifier().predict(
            context: context,
            modelState: prediction.sentenceState,
            silence: observation.silenceDurationAtEnd,
            pauseThreshold: AnalyticsMath.personalizedPauseThreshold(recentIntervals: baselineIntervals)
        )
        self.latestInterpretation = StackModelInterpretation(
            text: context.text,
            currentSentence: currentSentence(from: context.text),
            tokens: context.tokens,
            numericFeatures: Dictionary(uniqueKeysWithValues: zip(
                TextModelSchema.numericFeatureNames,
                textInput.numericFeatures.map(Double.init)
            )),
            rawState: prediction.state,
            rawProbabilities: prediction.probabilities,
            completion: completion
        )
        self.apply(prediction: prediction, to: &observation, context: context, completion: completion)
        return observation
    }

    private mutating func apply(
        prediction: WritingStatePrediction,
        to observation: inout SessionWindowObservation,
        context: WritingContextSnapshot,
        completion: StackSentenceCompletionPrediction
    ) {
        var temporal = prediction.temporalPrediction
        let hasText = context.characterCount > 0
        let textEvents = observation.printableCount + observation.deletionCount + observation.boundaryCount
        let hasTypingInWindow = textEvents > 0
        let otherEvents = observation.shortcutCount + observation.navigationKeyCount
            + observation.pointerMovementCount + observation.clickCount + observation.scrollCount
        let personalizedPause = AnalyticsMath.personalizedPauseThreshold(recentIntervals: baselineIntervals)
        let isPause = hasText && !hasTypingInWindow && otherEvents == 0
            && observation.silenceDurationAtEnd >= personalizedPause
        let sentenceState = completion.state

        if hasText && !hasTypingInWindow && otherEvents > 0 {
            consecutivePauseWindows = 0
            temporal = TemporalPrediction(
                state: .otherActivity,
                probabilities: resolvedProbabilities(from: prediction.temporalPrediction, state: .otherActivity, uncertainty: 0),
                sentenceState: sentenceState,
                activityState: .uncertain,
                confidence: prediction.confidence,
                isProvisional: false
            )
        } else if isPause {
            consecutivePauseWindows += 1
        } else {
            consecutivePauseWindows = 0
        }

        if isPause {
            // A pause is not a finished session just because it crossed one
            // short timeout. Keep it provisional for an adaptive 30–60 second
            // observation period; the next typing event can still reclassify
            // the provisional windows as thinking.
            let provisionalLimit = min(60, max(30, personalizedPause * 12))
            let finishEvidence = max(2, Int(ceil(provisionalLimit / Self.windowDuration)))
            if consecutivePauseWindows >= finishEvidence {
                temporal = TemporalPrediction(
                    state: .inactive,
                    probabilities: resolvedProbabilities(from: prediction.temporalPrediction, state: .inactive, uncertainty: 0),
                    sentenceState: sentenceState,
                    activityState: .finished,
                    confidence: max(prediction.confidence, 0.55),
                    isProvisional: false
                )
            } else {
                temporal = TemporalPrediction(
                    state: .uncertain,
                    probabilities: resolvedProbabilities(from: prediction.temporalPrediction, state: .uncertain, uncertainty: 0.35),
                    sentenceState: sentenceState,
                    activityState: .uncertain,
                    confidence: prediction.confidence,
                    isProvisional: true
                )
            }
        } else if prediction.confidence < 0.45 {
            temporal = TemporalPrediction(
                state: .uncertain,
                probabilities: resolvedProbabilities(from: prediction.temporalPrediction, state: .uncertain, uncertainty: 0.45),
                sentenceState: sentenceState,
                activityState: .uncertain,
                confidence: prediction.confidence,
                isProvisional: true
            )
        }

        temporal.sentenceState = sentenceState
        observation.inferredState = temporal.state
        if temporal.probabilities[TypingBehaviorState.uncertain.rawValue] == nil {
            temporal.probabilities[TypingBehaviorState.uncertain.rawValue] = 0
        }
        observation.stateProbabilities = temporal.probabilities
        latestSentenceState = temporal.sentenceState
        latestActivityState = temporal.activityState
        latestPredictionConfidence = temporal.confidence
        latestPredictionIsProvisional = temporal.isProvisional
    }

    private func currentSentence(from text: String) -> String {
        let start = text.lastIndex(where: { ".?!".contains($0) }).map { text.index(after: $0) } ?? text.startIndex
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedProbabilities(
        from original: TemporalPrediction,
        state: TypingBehaviorState,
        uncertainty: Double
    ) -> [String: Double] {
        let boundedUncertainty = min(max(uncertainty, 0), 1)
        let scale = 1 - boundedUncertainty
        var result = original.probabilities.mapValues { $0 * scale }
        result[TypingBehaviorState.uncertain.rawValue] = boundedUncertainty
        if state == .inactive { result[TypingBehaviorState.inactive.rawValue] = max(result[TypingBehaviorState.inactive.rawValue] ?? 0, 0.55) }
        if state == .otherActivity { result[TypingBehaviorState.otherActivity.rawValue] = max(result[TypingBehaviorState.otherActivity.rawValue] ?? 0, 0.55) }
        if state == .uncertain { result[TypingBehaviorState.uncertain.rawValue] = max(result[TypingBehaviorState.uncertain.rawValue] ?? 0, boundedUncertainty) }
        let total = result.values.reduce(0, +)
        return total > 0 ? result.mapValues { $0 / total } : [state.rawValue: 1]
    }

    private mutating func reconcileResumedTyping() {
        guard let index = observations.indices.last,
              observations[index].inferredState == .uncertain else { return }
        observations[index].inferredState = .thinking
        observations[index].stateProbabilities[TypingBehaviorState.uncertain.rawValue] = 0
        observations[index].stateProbabilities[TypingBehaviorState.thinking.rawValue] = 1
        latestActivityState = .thinking
        latestPredictionIsProvisional = false
        consecutivePauseWindows = 0
    }

    private mutating func clearWindow(startingAt date: Date) {
        windowStartedAt = date
        printableCount = 0
        deletionCount = 0
        boundaryCount = 0
        shortcutCount = 0
        navigationKeyCount = 0
        repeatedKeyCount = 0
        pointerMovementCount = 0
        pointerDistance = 0
        clickCount = 0
        scrollCount = 0
        scrollDistance = 0
        intervals = []
    }

    private func intervalHistogram(_ values: [TimeInterval]) -> [Int] {
        let bounds: [TimeInterval] = [0.05, 0.10, 0.20, 0.50, 1, 2]
        var buckets = [Int](repeating: 0, count: bounds.count + 1)
        for value in values {
            let index = bounds.firstIndex(where: { value < $0 }) ?? bounds.count
            buckets[index] += 1
        }
        return buckets
    }
}

private extension BehavioralEventKind {
    var isTyping: Bool {
        switch self {
        case .printable, .deletion, .boundary: true
        default: false
        }
    }
}
