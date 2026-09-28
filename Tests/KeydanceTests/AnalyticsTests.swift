import XCTest
@testable import Keydance

final class AnalyticsTests: XCTestCase {
    func testStandardWPMAndCPM() {
        let summary = makeSummary(printable: 250, seconds: 60)
        XCTAssertEqual(summary.wordsPerMinute, 50, accuracy: 0.001)
        XCTAssertEqual(summary.charactersPerMinute, 250, accuracy: 0.001)
    }

    func testBenchmarkAccuracy() {
        var summary = makeSummary(printable: 100, seconds: 60, kind: .benchmark)
        summary.correctCount = 90
        summary.incorrectCount = 10
        XCTAssertEqual(summary.accuracy, 0.9, accuracy: 0.001)
    }

    func testPauseThresholdIsAdaptiveAndClamped() {
        XCTAssertEqual(AnalyticsMath.pauseThreshold(recentIntervals: [0.1, 0.12, 0.14]), 0.8)
        XCTAssertEqual(AnalyticsMath.pauseThreshold(recentIntervals: [2, 2.1, 2.2]), 3)
        XCTAssertEqual(AnalyticsMath.pauseThreshold(recentIntervals: [0.3, 0.4, 0.5]), 2)
    }

    func testPersonalizedPauseThresholdNeedsEnoughStableTimingData() {
        XCTAssertEqual(AnalyticsMath.personalizedPauseThreshold(recentIntervals: [0.1, 0.2, 0.3, 0.4]), 1.2)
        let threshold = AnalyticsMath.personalizedPauseThreshold(recentIntervals: Array(repeating: 0.4, count: 30))
        XCTAssertGreaterThan(threshold, 1.2)
        XCTAssertLessThanOrEqual(threshold, 8)
    }

    func testPercentileInterpolatesTimingSamples() {
        XCTAssertEqual(AnalyticsMath.percentile([0.1, 0.2, 0.3, 0.4], percentile: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(AnalyticsMath.percentile([0.1, 0.2, 0.3], percentile: 0.9), 0.28, accuracy: 0.0001)
    }

    func testEstimatorOnlyReportsUniqueCloseMatch() {
        let estimator = DictionaryEstimator(words: ["the", "there", "house", "mouse"])
        XCTAssertEqual(estimator.classify(token: "the"), .known)
        XCTAssertEqual(estimator.classify(token: "thw"), .likelyMisspelling(suggestion: "the"))
        XCTAssertEqual(estimator.classify(token: "rouse"), .unknown, "Two one-edit matches must be treated as ambiguous")
        XCTAssertEqual(estimator.classify(token: "xylophonic"), .unknown)
    }

    func testSentenceAccuracyCountsUncorrectedSpellingDistance() throws {
        let estimator = DictionaryEstimator(words: ["i", "really", "like", "this"])
        var accumulator = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
        for character in "I realy like this." { accumulator.record(character) }

        let sample = try XCTUnwrap(accumulator.samples.first)
        XCTAssertTrue(sample.isComplete)
        XCTAssertEqual(sample.spellingErrorCharacters, 1)
        XCTAssertEqual(sample.backspaceErrorCharacters, 0)
        XCTAssertEqual(sample.contextErrorCharacters, 0)
        XCTAssertLessThan(sample.accuracy, 1)
    }

    func testSentenceAccuracyCatchesTrailingExtraLetter() throws {
        let estimator = DictionaryEstimator(words: ["say", "saw", "says"])
        var accumulator = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
        for character in "sayu." { accumulator.record(character) }

        let sample = try XCTUnwrap(accumulator.samples.first)
        XCTAssertEqual(sample.spellingErrorCharacters, 1)
        XCTAssertEqual(accumulator.trace.spellingCandidates, ["sayu → say"])
        XCTAssertLessThan(sample.accuracy, 1)
    }

    func testSentenceAccuracyCountsBackspaceCorrectionsEvenWhenFinalWordIsCorrect() throws {
        let estimator = DictionaryEstimator(words: ["the"])
        var accumulator = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
        for character in "teh" { accumulator.record(character) }
        accumulator.recordDeletion()
        accumulator.recordDeletion()
        for character in "he." { accumulator.record(character) }

        let sample = try XCTUnwrap(accumulator.samples.first)
        XCTAssertEqual(sample.spellingErrorCharacters, 0)
        XCTAssertEqual(sample.backspaceErrorCharacters, 2)
        XCTAssertEqual(accumulator.totals.errorCharacters, 2)
    }

    func testSentenceAccuracyFindsHighConfidenceWhoHowContextError() throws {
        let estimator = DictionaryEstimator(words: ["who", "how", "is", "the", "weather", "today"])
        var accumulator = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
        for character in "Who is the weather today?" { accumulator.record(character) }

        let sample = try XCTUnwrap(accumulator.samples.first)
        XCTAssertEqual(sample.spellingErrorCharacters, 0, "Both words are individually spelled correctly")
        XCTAssertEqual(sample.contextErrorCharacters, 2, "who -> how has a two-edit distance")
    }

    func testSentenceAccuracyDoesNotPunishNormalWhoSentenceOrUnknownTerm() throws {
        let estimator = DictionaryEstimator(words: ["who", "is", "the", "teacher", "today"])
        var accumulator = SentenceAccuracyAccumulator(checker: SentenceAccuracyChecker(estimator: estimator))
        for character in "Who is the teacher today?" { accumulator.record(character) }
        for character in " XylophonicTerm." { accumulator.record(character) }

        XCTAssertEqual(accumulator.totals.contextErrorCharacters, 0)
        XCTAssertEqual(accumulator.totals.spellingErrorCharacters, 0, "Unknown terms are not confidently misspelled")
    }

    func testSentenceAccuracyResetsAtEachSentenceAndIgnoresPointerActivity() throws {
        let estimator = DictionaryEstimator(words: ["hello", "world", "next"])
        var engine = TypingEngine(estimator: estimator)
        let start = Date(timeIntervalSince1970: 900)
        for (offset, character) in Array("Hello world.").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.1)
            if character.isWhitespace { _ = engine.consume(.boundary(character, at: date)) }
            else { _ = engine.consume(.printable(character, keyLabel: String(character), at: date)) }
        }
        _ = engine.consume(.pointerMovement(distance: 50, eventCount: 2, at: start.addingTimeInterval(3)))
        for (offset, character) in Array(" Next.").enumerated() {
            let date = start.addingTimeInterval(4 + Double(offset) * 0.1)
            if character.isWhitespace { _ = engine.consume(.boundary(character, at: date)) }
            else { _ = engine.consume(.printable(character, keyLabel: String(character), at: date)) }
        }

        let snapshot = engine.diagnosticSnapshot(at: start.addingTimeInterval(6))
        XCTAssertEqual(snapshot.sentenceAccuracySamples.count, 2)
        XCTAssertEqual(snapshot.accuracyTotals.sentenceCount, 2)
        XCTAssertEqual(snapshot.accuracyTotals.errorCharacters, 0)
        XCTAssertEqual(snapshot.accuracyTotals.accuracy, 1, accuracy: 0.001)
    }

    func testCorrectedErrorAndConfusionAreAggregated() throws {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["cat"]))
        let start = Date(timeIntervalSince1970: 1_000)
        _ = engine.consume(.printable("c", keyLabel: "c", at: start))
        _ = engine.consume(.printable("x", keyLabel: "x", at: start.addingTimeInterval(0.1)))
        _ = engine.consume(.deletion(at: start.addingTimeInterval(0.2)))
        _ = engine.consume(.printable("a", keyLabel: "a", at: start.addingTimeInterval(0.3)))
        _ = engine.consume(.printable("t", keyLabel: "t", at: start.addingTimeInterval(0.4)))
        _ = engine.consume(.boundary(" ", at: start.addingTimeInterval(0.5)))
        let result = try XCTUnwrap(engine.finalize(at: start.addingTimeInterval(1)))
        XCTAssertEqual(result.correctedErrors, 1)
        XCTAssertEqual(result.confusions.first(where: { $0.from == "x" && $0.to == "a" })?.count, 1)
        XCTAssertEqual(result.coveredCharacters, 3)
    }

    func testSustainedInactivityEndsSessionThroughTemporalFallback() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KEYDANCE_TEXT_MODEL"] != nil)
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["a"]))
        let start = Date(timeIntervalSince1970: 2_000)
        for offset in 0..<40 {
            _ = engine.consume(.printable("a", keyLabel: "a", at: start.addingTimeInterval(Double(offset) * 0.1)))
        }
        let previous = try XCTUnwrap(engine.advance(to: start.addingTimeInterval(180)))
        XCTAssertEqual(previous.hmmModelVersion, TemporalSessionTracker.modelVersion)
        XCTAssertFalse(previous.observationWindows.isEmpty)
        XCTAssertTrue(previous.observationWindows.contains { $0.inferredState == .writing })
        XCTAssertTrue(previous.observationWindows.contains { $0.inferredState == .inactive })
        XCTAssertLessThan(previous.endedAt, start.addingTimeInterval(180))
        XCTAssertGreaterThan(previous.activeWordsPerMinute, previous.wordsPerMinute)
        _ = engine.consume(.printable("b", keyLabel: "b", at: start.addingTimeInterval(181)))
        XCTAssertNotNil(engine.startedAt, "The input after the cutoff starts a new session")
    }

    func testThinkingPauseDoesNotSplitSession() {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["a"]))
        let start = Date(timeIntervalSince1970: 3_000)
        for offset in 0..<30 {
            _ = engine.consume(.printable("a", keyLabel: "a", at: start.addingTimeInterval(Double(offset) * 0.1)))
        }
        XCTAssertNil(engine.advance(to: start.addingTimeInterval(10)))
        _ = engine.consume(.printable("b", keyLabel: "b", at: start.addingTimeInterval(11)))
        XCTAssertNotNil(engine.startedAt)
    }

    func testProvisionalPauseIsReclassifiedWhenTypingResumes() throws {
        var tracker = TemporalSessionTracker()
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 3_500)
        tracker.start(at: start)
        tracker.record(.printable(isRepeat: false), at: start)
        context.recordPrintable("a", at: start)
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(10), writingContext: context))
        XCTAssertEqual(tracker.observations.last?.inferredState, .uncertain)

        tracker.record(.printable(isRepeat: false), at: start.addingTimeInterval(11))
        XCTAssertEqual(tracker.observations.last?.inferredState, .thinking)
        XCTAssertFalse(tracker.diagnostics(at: start.addingTimeInterval(11)).latestPredictionIsProvisional)
    }

    func testSustainedUncertainPauseEventuallyEndsSession() throws {
        var tracker = TemporalSessionTracker()
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 3_800)
        tracker.start(at: start)
        tracker.record(.printable(isRepeat: false), at: start)
        context.recordPrintable("a", at: start)
        XCTAssertNotNil(tracker.advance(to: start.addingTimeInterval(65), writingContext: context))
        XCTAssertTrue(tracker.observations.contains { $0.inferredState == .inactive })
    }

    func testWritingAndActiveWPMUseDifferentEligibleDurations() {
        var summary = makeSummary(printable: 40, seconds: 16)
        summary.activeDuration = 8
        XCTAssertEqual(summary.writingWordsPerMinute, 30, accuracy: 0.001)
        XCTAssertEqual(summary.activeTypingWordsPerMinute, 60, accuracy: 0.001)
    }

    func testLiveSnapshotReportsRawAndModelFilteredSentenceSpeed() throws {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["hello", "world"]))
        let start = Date(timeIntervalSince1970: 4_600)
        for (offset, character) in Array("hello world.").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.2)
            if character.isWhitespace {
                _ = engine.consume(.boundary(character, at: date))
            } else {
                _ = engine.consume(.printable(character, keyLabel: String(character), at: date))
            }
        }
        XCTAssertNil(engine.advance(to: start.addingTimeInterval(5)))

        let snapshot = engine.diagnosticSnapshot(at: start.addingTimeInterval(5.25))
        let sentence = try XCTUnwrap(snapshot.sentenceSpeeds.last)
        XCTAssertEqual(sentence.characterCount, 12)
        XCTAssertTrue(sentence.isComplete)
        XCTAssertGreaterThan(sentence.rawWordsPerMinute, 0)
        XCTAssertGreaterThanOrEqual(sentence.intentionalWordsPerMinute ?? 0, 0)
        XCTAssertGreaterThanOrEqual(sentence.modelCoverage, 0)
        XCTAssertGreaterThan(snapshot.rawWordsPerMinute, 0)
        XCTAssertGreaterThanOrEqual(snapshot.intentionalWordsPerMinute, 0)
    }

    func testIncompleteSentenceIsShownAsCurrentSpeedSample() throws {
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 4_700)
        for (offset, character) in Array("keep going").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.15)
            if character.isWhitespace { context.recordBoundary(character, at: date) }
            else { context.recordPrintable(character, at: date) }
        }

        let snapshot = context.snapshot(at: start.addingTimeInterval(5))
        let sentence = try XCTUnwrap(snapshot.sentenceTimings.last)
        XCTAssertFalse(sentence.isComplete)
        XCTAssertEqual(sentence.characterCount, 10)
        XCTAssertEqual(snapshot.completedSentenceCount, 0)
    }

    func testSentenceTimerStopsAtPunctuationUntilNextSentenceStarts() throws {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["hi", "next"]))
        let start = Date(timeIntervalSince1970: 4_750)
        for (offset, character) in Array("Hi.").enumerated() {
            _ = engine.consume(.printable(character, keyLabel: String(character), at: start.addingTimeInterval(Double(offset) * 0.2)))
        }

        let paused = engine.diagnosticSnapshot(at: start.addingTimeInterval(10))
        let first = try XCTUnwrap(paused.sentenceSpeeds.first)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.rawDuration, 0.4, accuracy: 0.001)

        for (offset, character) in Array("Next.").enumerated() {
            _ = engine.consume(.printable(character, keyLabel: String(character), at: start.addingTimeInterval(10.1 + Double(offset) * 0.2)))
        }
        let resumed = engine.diagnosticSnapshot(at: start.addingTimeInterval(11.5))
        XCTAssertEqual(resumed.sentenceSpeeds.count, 2)
        XCTAssertEqual(resumed.sentenceSpeeds.first?.rawDuration ?? -1, 0.4, accuracy: 0.001)
    }

    func testMouseBoundaryFreezesSentenceTimingUntilTypingResumes() throws {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["hello", "world"]))
        let start = Date(timeIntervalSince1970: 4_850)
        for (offset, character) in Array("hello").enumerated() {
            _ = engine.consume(.printable(character, keyLabel: String(character), at: start.addingTimeInterval(Double(offset) * 0.15)))
        }
        _ = engine.consume(.pointerMovement(distance: 80, eventCount: 4, at: start.addingTimeInterval(2)))
        XCTAssertTrue(engine.diagnosticSnapshot(at: start.addingTimeInterval(3)).timingPaused)
        for (offset, character) in Array(" world.").enumerated() {
            let date = start.addingTimeInterval(10 + Double(offset) * 0.15)
            if character.isWhitespace {
                _ = engine.consume(.boundary(character, at: date))
            } else {
                _ = engine.consume(.printable(character, keyLabel: String(character), at: date))
            }
        }

        let snapshot = engine.diagnosticSnapshot(at: start.addingTimeInterval(12))
        let sentence = try XCTUnwrap(snapshot.sentenceSpeeds.last)
        XCTAssertFalse(snapshot.timingPaused)
        XCTAssertTrue(sentence.isComplete)
        XCTAssertLessThan(sentence.rawDuration, 2, "The mouse-to-resume gap must not lower sentence WPM")
        XCTAssertGreaterThan(snapshot.rawWordsPerMinute, 60, "Raw WPM should use timed bursts, not the ten-second wall gap")
    }

    func testOtherKeyboardActivityHasItsOwnTemporalState() {
        var tracker = TemporalSessionTracker()
        let start = Date(timeIntervalSince1970: 4_000)
        tracker.start(at: start)
        for offset in 0..<8 {
            tracker.record(.shortcut, at: start.addingTimeInterval(Double(offset) * 0.4))
        }
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5)))
        XCTAssertEqual(tracker.observations.first?.inferredState, .otherActivity)
        XCTAssertEqual(tracker.observations.first?.shortcutCount, 8)
        XCTAssertEqual(tracker.observations.first?.navigationKeyCount, 0)
        XCTAssertEqual(tracker.observations.first?.interKeyIntervalHistogram.reduce(0, +), 7)
    }

    func testPointerActivityDuringPauseDoesNotBecomeFinished() {
        var tracker = TemporalSessionTracker()
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 4_500)
        tracker.start(at: start)
        tracker.record(.printable(isRepeat: false), at: start)
        context.recordPrintable("a", at: start)
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5), writingContext: context))

        tracker.record(.pointerMovement(distance: 10, eventCount: 1), at: start.addingTimeInterval(6))
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(10), writingContext: context))
        XCTAssertEqual(tracker.observations.last?.inferredState, .otherActivity)
    }

    func testRepeatedKeysAreCountedWithoutKeepingKeyIdentity() {
        var tracker = TemporalSessionTracker()
        let start = Date(timeIntervalSince1970: 4_500)
        tracker.record(.printable(isRepeat: false), at: start)
        tracker.record(.printable(isRepeat: true), at: start.addingTimeInterval(0.1))
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5)))
        XCTAssertEqual(tracker.observations.first?.printableCount, 2)
        XCTAssertEqual(tracker.observations.first?.repeatedKeyCount, 1)
    }

    func testWritingContextTracksWordsTimingAndSentenceBoundaryInMemory() {
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 5_100)
        for (offset, character) in Array("hello world.").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.2)
            if character.isWhitespace {
                context.recordBoundary(character, at: date)
            } else {
                context.recordPrintable(character, at: date)
            }
        }

        let snapshot = context.snapshot(at: start.addingTimeInterval(4))
        XCTAssertEqual(snapshot.text, "hello world.")
        XCTAssertEqual(snapshot.tokens, ["hello", "world."])
        XCTAssertEqual(snapshot.wordCount, 2)
        XCTAssertEqual(snapshot.completedSentenceCount, 1)
        XCTAssertFalse(snapshot.hasUnfinishedSentence)
        XCTAssertTrue(snapshot.endsWithSentencePunctuation)
        XCTAssertEqual(snapshot.wordTimings.count, 2)
        XCTAssertEqual(snapshot.wordTimings[0].duration, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.wordTimings[1].gapBefore, 0.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.secondsSinceLastCharacter ?? -1, 1.8, accuracy: 0.001)

        context.reset()
        XCTAssertEqual(context.snapshot(at: start).text, "")
    }

    func testWritingContextDeletionRemovesLastCharacter() {
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 5_200)
        context.recordPrintable("a", at: start)
        context.recordPrintable("b", at: start.addingTimeInterval(0.1))
        context.recordDeletion()

        let snapshot = context.snapshot(at: start.addingTimeInterval(1))
        XCTAssertEqual(snapshot.text, "a")
        XCTAssertEqual(snapshot.correctionCount, 1)
    }

    func testTextAwareModelInputUsesFixedShape() {
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 5_300)
        for (offset, character) in Array("hello world").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.1)
            if character.isWhitespace {
                context.recordBoundary(character, at: date)
            } else {
                context.recordPrintable(character, at: date)
            }
        }
        var tracker = TemporalSessionTracker()
        tracker.record(.printable(isRepeat: false), at: start)
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5)))
        let frame = try! XCTUnwrap(tracker.observations.first)
        let input = TextAwareModelInput(frame: frame, context: context.snapshot(at: start.addingTimeInterval(5)))

        XCTAssertEqual(input.tokenIDs.count, TextModelSchema.maxTokens)
        XCTAssertEqual(input.wordDurations.count, TextModelSchema.maxTokens)
        XCTAssertEqual(input.wordGaps.count, TextModelSchema.maxTokens)
        XCTAssertEqual(input.numericFeatures.count, TextModelSchema.numericFeatureNames.count)
        XCTAssertTrue(input.tokenIDs.contains(where: { $0 > 1 }))
    }

    func testTextAwareFallbackDistinguishesUnfinishedAndCompletedSentence() {
        let start = Date(timeIntervalSince1970: 5_400)
        let fallback = TextAwareFallbackClassifier()

        var unfinished = WritingContextBuffer()
        for (offset, character) in Array("keep going").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.1)
            if character.isWhitespace {
                unfinished.recordBoundary(character, at: date)
            } else {
                unfinished.recordPrintable(character, at: date)
            }
        }
        var unfinishedTracker = TemporalSessionTracker()
        unfinishedTracker.record(.printable(isRepeat: false), at: start)
        XCTAssertNil(unfinishedTracker.advance(to: start.addingTimeInterval(5)))
        let unfinishedFrame = try! XCTUnwrap(unfinishedTracker.observations.first)
        let unfinishedPrediction = fallback.infer(input: TextAwareModelInput(
            frame: unfinishedFrame,
            context: unfinished.snapshot(at: start.addingTimeInterval(5))
        ))
        XCTAssertEqual(unfinishedPrediction.state, .midThought)

        var complete = WritingContextBuffer()
        for (offset, character) in Array("done.").enumerated() {
            complete.recordPrintable(character, at: start.addingTimeInterval(Double(offset) * 0.1))
        }
        let completePrediction = fallback.infer(input: TextAwareModelInput(
            frame: unfinishedFrame,
            context: complete.snapshot(at: start.addingTimeInterval(5))
        ))
        XCTAssertEqual(completePrediction.state, .sentenceComplete)
    }

    func testStackCompletionReplayMatrixUsesTheSameModelInputPath() throws {
        struct Case {
            let text: String
            let expected: SentenceState
        }

        let cases = [
            Case(text: "I was thinking about", expected: .incomplete),
            Case(text: "I am not sure whether", expected: .incomplete),
            Case(text: "because the meeting was", expected: .incomplete),
            Case(text: "The cat sat on", expected: .incomplete),
            Case(text: "I need to", expected: .incomplete),
            Case(text: "in the morning", expected: .incomplete),
            Case(text: "First sentence. because the meeting was", expected: .incomplete),
            Case(text: "I will see you tomorrow", expected: .likelyComplete),
            Case(text: "The meeting ended early", expected: .likelyComplete),
            Case(text: "Can you send it", expected: .likelyComplete),
            Case(text: "What time is it", expected: .likelyComplete),
            Case(text: "I went to go home", expected: .likelyComplete),
            Case(text: "Were are my keys", expected: .likelyComplete),
            Case(text: "Thanks for your help", expected: .likelyComplete),
            Case(text: "First sentence. The meeting ended early", expected: .likelyComplete),
            Case(text: "okay", expected: .likelyComplete),
            Case(text: "The meeting ended early.", expected: .likelyComplete),
        ]

        let classifier = StackSentenceCompletionClassifier()
        let start = Date(timeIntervalSince1970: 7_000)
        for (index, testCase) in cases.enumerated() {
            var context = WritingContextBuffer()
            var tracker = TemporalSessionTracker()
            for (offset, character) in Array(testCase.text).enumerated() {
                let date = start.addingTimeInterval(Double(offset) * 0.08)
                if character.isWhitespace {
                    tracker.record(.boundary, at: date)
                    context.recordBoundary(character, at: date)
                } else {
                    tracker.record(.printable(isRepeat: false), at: date)
                    context.recordPrintable(character, at: date)
                }
            }
            XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5), writingContext: context))
            let frame = try XCTUnwrap(tracker.observations.first)
            let snapshot = context.snapshot(at: start.addingTimeInterval(7))
            let input = TextAwareModelInput(frame: frame, context: snapshot)
            let modelPrediction = SessionTextModelRuntime.shared.predict(input: input)
                ?? TextAwareFallbackClassifier().infer(input: input)
            let result = classifier.predict(
                context: snapshot,
                modelState: modelPrediction.sentenceState,
                silence: 2,
                pauseThreshold: 1.2
            )
            let score = String(format: "%.2f", result.completionScore)
            print("Stack replay [\(index)] \(testCase.text.debugDescription): raw=\(modelPrediction.state.rawValue) hybrid=\(result.state.rawValue) score=\(score) reason=\(result.reason)")
            XCTAssertEqual(result.state, testCase.expected, testCase.text)
            XCTAssertEqual(input.tokenIDs.count, TextModelSchema.maxTokens)
        }
    }

    func testCoreMLTextPredictionWhenModelOverrideIsProvided() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYDANCE_TEXT_MODEL"] != nil)
        var tracker = TemporalSessionTracker()
        let start = Date(timeIntervalSince1970: 5_450)
        for offset in 0..<30 {
            tracker.record(.printable(isRepeat: false), at: start.addingTimeInterval(Double(offset) * 0.1))
        }
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5)))
        let diagnostics = tracker.diagnostics(at: start.addingTimeInterval(5))
        XCTAssertEqual(diagnostics.inferenceBackend, "Core ML text model")
        XCTAssertEqual(diagnostics.latestProbabilities.count, 5)
        XCTAssertEqual(diagnostics.latestProbabilities.values.reduce(0, +), 1, accuracy: 0.001)
    }

    func testCoreMLPauseIsProvisionalUntilTypingResumes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYDANCE_TEXT_MODEL"] != nil)
        var tracker = TemporalSessionTracker()
        var context = WritingContextBuffer()
        let start = Date(timeIntervalSince1970: 5_600)
        tracker.start(at: start)
        for (offset, character) in Array("I was thinking about").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.08)
            tracker.record(character == " " ? .boundary : .printable(isRepeat: false), at: date)
            if character == " " { context.recordBoundary(character, at: date) }
            else { context.recordPrintable(character, at: date) }
        }
        XCTAssertNil(tracker.advance(to: start.addingTimeInterval(10), writingContext: context))
        XCTAssertEqual(tracker.observations.last?.inferredState, .uncertain)

        tracker.record(.printable(isRepeat: false), at: start.addingTimeInterval(11))
        XCTAssertEqual(tracker.observations.last?.inferredState, .thinking)
    }

    func testCoreMLSentenceBoundaryProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYDANCE_TEXT_MODEL"] != nil)

        func predict(_ text: String, startingAt start: Date) throws -> (WritingStatePrediction, SentenceState) {
            var context = WritingContextBuffer()
            var tracker = TemporalSessionTracker()
            for (offset, character) in Array(text).enumerated() {
                let date = start.addingTimeInterval(Double(offset) * 0.08)
                if character.isWhitespace {
                    tracker.record(.boundary, at: date)
                    context.recordBoundary(character, at: date)
                } else {
                    tracker.record(.printable(isRepeat: false), at: date)
                    context.recordPrintable(character, at: date)
                }
            }
            XCTAssertNil(tracker.advance(to: start.addingTimeInterval(5), writingContext: context))
            let frame = try XCTUnwrap(tracker.observations.first)
            let prediction = try XCTUnwrap(SessionTextModelRuntime.shared.predict(input: TextAwareModelInput(
                frame: frame,
                context: context.snapshot(at: start.addingTimeInterval(5))
            )))
            let diagnostics = tracker.diagnostics(at: start.addingTimeInterval(5))
            return (prediction, diagnostics.latestSentenceState)
        }

        let unfinished = try predict("I was thinking about", startingAt: Date(timeIntervalSince1970: 6_100))
        let finished = try predict("I'll see you tomorrow.", startingAt: Date(timeIntervalSince1970: 6_200))
        func top(_ prediction: WritingStatePrediction) -> String {
            prediction.probabilities.max { $0.value < $1.value }?.key ?? "none"
        }
        print("Core ML sentence probe: unfinished raw=\(top(unfinished.0)) modelSentence=\(unfinished.0.sentenceState) hybridSentence=\(unfinished.1) probs=\(unfinished.0.probabilities); finished raw=\(top(finished.0)) modelSentence=\(finished.0.sentenceState) hybridSentence=\(finished.1) probs=\(finished.0.probabilities)")
        XCTAssertEqual(unfinished.0.probabilities.count, WritingState.allCases.count)
        XCTAssertEqual(finished.0.probabilities.count, WritingState.allCases.count)
        XCTAssertEqual(unfinished.1, .incomplete)
        XCTAssertEqual(finished.1, .likelyComplete)
    }

    func testDevConsoleSnapshotIncludesLiveAndCompletedFrameTelemetry() {
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["a"]))
        let start = Date(timeIntervalSince1970: 4_800)
        _ = engine.consume(.printable("a", keyLabel: "a", at: start))
        _ = engine.consume(.printable("a", keyLabel: "a", isRepeat: true, at: start.addingTimeInterval(0.1)))
        _ = engine.consume(.boundary(" ", at: start.addingTimeInterval(0.2)))
        _ = engine.consume(.deletion(at: start.addingTimeInterval(0.3)))
        _ = engine.consume(.shortcut(at: start.addingTimeInterval(0.4)))
        _ = engine.consume(.navigation(at: start.addingTimeInterval(0.5)))
        _ = engine.consume(.pointerMovement(distance: 120, eventCount: 4, at: start.addingTimeInterval(0.6)))
        _ = engine.consume(.click(at: start.addingTimeInterval(0.7)))
        _ = engine.consume(.scroll(distance: 24, at: start.addingTimeInterval(0.8)))
        XCTAssertNil(engine.advance(to: start.addingTimeInterval(5)))

        let snapshot = engine.diagnosticSnapshot(at: start.addingTimeInterval(5.25))
        XCTAssertTrue(snapshot.hasActiveSession)
        XCTAssertEqual(snapshot.printableCount, 2)
        XCTAssertEqual(snapshot.deletionCount, 1)
        XCTAssertEqual(snapshot.hmm.completedFrameCount, 1)
        XCTAssertEqual(snapshot.hmm.totalBoundaryCount, 1)
        XCTAssertEqual(snapshot.hmm.totalShortcutCount, 1)
        XCTAssertEqual(snapshot.hmm.totalNavigationCount, 1)
        XCTAssertEqual(snapshot.hmm.totalRepeatedKeyCount, 1)
        XCTAssertEqual(snapshot.hmm.totalPointerMovementCount, 4)
        XCTAssertEqual(snapshot.hmm.totalPointerDistance, 120, accuracy: 0.001)
        XCTAssertEqual(snapshot.hmm.totalClickCount, 1)
        XCTAssertEqual(snapshot.hmm.totalScrollCount, 1)
        XCTAssertEqual(snapshot.hmm.totalScrollDistance, 24, accuracy: 0.001)
        XCTAssertEqual(snapshot.hmm.latestObservation?.eventCount, 12)
        XCTAssertEqual(snapshot.hmm.currentFrameElapsed, 0.25, accuracy: 0.001)
        XCTAssertFalse(snapshot.hmm.latestProbabilities.isEmpty)
        XCTAssertEqual(snapshot.hmm.latestTextModelProbabilities.count, WritingState.allCases.count)
        XCTAssertEqual(snapshot.hmm.latestInterpretation?.text, "aa")
        XCTAssertEqual(snapshot.hmm.latestInterpretation?.currentSentence, "aa")
        XCTAssertEqual(snapshot.hmm.latestInterpretation?.tokens, ["aa"])
        XCTAssertEqual(snapshot.hmm.latestInterpretation?.numericFeatures.count, TextModelSchema.numericFeatureNames.count)
        XCTAssertFalse(snapshot.hmm.latestInterpretation?.rawProbabilityLine.isEmpty ?? true)
    }

    @MainActor
    func testTemporalFeatureFramesPersistWithoutRawEvents() throws {
        let store = try AnalyticsStore(inMemory: true)
        var engine = TypingEngine(estimator: DictionaryEstimator(words: ["test"]))
        let start = Date(timeIntervalSince1970: 5_000)
        for (offset, character) in Array("test test").enumerated() {
            let date = start.addingTimeInterval(Double(offset) * 0.15)
            if character == " " { _ = engine.consume(.boundary(character, at: date)) }
            else { _ = engine.consume(.printable(character, keyLabel: String(character), at: date)) }
        }
        let summary = try XCTUnwrap(engine.finalize(at: start.addingTimeInterval(6)))
        try store.save(summary)
        let record = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(record.hmmModelVersion, TemporalSessionTracker.modelVersion)
        XCTAssertEqual(record.featureFrameCount, summary.observationWindows.count)
        XCTAssertEqual(record.observationWindows, summary.observationWindows)
        let persistedFrames = String(data: record.featureFramesData, encoding: .utf8) ?? ""
        XCTAssertFalse(persistedFrames.contains("wordTimings"))
        XCTAssertFalse(persistedFrames.contains("currentSentenceCharacterCount"))
    }

    func testLocalDayUsesProvidedCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        let date = ISO8601DateFormatter().date(from: "2024-01-01T07:00:00Z")!
        let components = calendar.dateComponents([.year, .month, .day], from: AnalyticsMath.localDay(for: date, calendar: calendar))
        XCTAssertEqual(components.year, 2023)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 31)
    }

    @MainActor
    func testDownsamplingKeepsNewestLimitAndPreservesOldTotals() throws {
        XCTAssertEqual(AnalyticsStore.defaultDetailLimit, 1_000)
        let store = try AnalyticsStore(inMemory: true, detailLimit: 10)
        let base = Date(timeIntervalSince1970: 10_000)
        for offset in 0...10 {
            var summary = makeSummary(printable: 10, seconds: 10)
            summary.startedAt = base.addingTimeInterval(Double(offset) * 20)
            summary.endedAt = summary.startedAt.addingTimeInterval(10)
            try store.save(summary)
        }
        XCTAssertEqual(store.sessions.count, 10)
        XCTAssertEqual(store.sessions.last?.startedAt, base.addingTimeInterval(20))
        XCTAssertEqual(store.rollups.reduce(0) { $0 + $1.sessionCount }, 1)
        XCTAssertEqual(store.rollups.reduce(0) { $0 + $1.characterTotal }, 10)
    }

    private func makeSummary(printable: Int, seconds: TimeInterval, kind: SessionKind = .passive) -> SessionSummary {
        let start = Date(timeIntervalSince1970: 0)
        return SessionSummary(kind: kind, startedAt: start, endedAt: start.addingTimeInterval(seconds), printableCount: printable, correctCount: 0, incorrectCount: 0, deletionCount: 0, correctedErrors: 0, uncorrectedEstimate: 0, coveredCharacters: printable, activeDuration: seconds, midSentencePauses: [], betweenSentencePauses: [], keyStats: [], confusions: [])
    }
}
