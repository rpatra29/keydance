import XCTest
@testable import Keydance

final class VocabularyTests: XCTestCase {
    func testBundledVocabularyPassesContentAudit() throws {
        let words = Vocabulary.load()
        let denied = Vocabulary.deniedTerms()

        XCTAssertEqual(words.count, 1_000)
        XCTAssertEqual(Set(words).count, words.count, "Vocabulary entries must be unique")
        XCTAssertTrue(words.allSatisfy { $0 == $0.lowercased() && $0.allSatisfy(\.isLetter) })
        XCTAssertTrue(denied.isDisjoint(with: words), "A denied term entered the benchmark vocabulary")
    }

    func testPersistentModelsDoNotContainCapturedContentFields() {
        let prohibitedFragments = ["text", "word", "sentence", "application", "window", "clipboard", "sequence", "rawkey"]
        let persistedNames = [
            "id", "kindRaw", "startedAt", "endedAt", "printableCount", "correctCount", "incorrectCount",
            "deletionCount", "correctedErrors", "uncorrectedEstimate", "coveredCharacters", "activeDuration",
            "midPauseCount", "midPauseTotal", "midPauseMedian", "betweenPauseCount", "betweenPauseTotal",
            "betweenPauseMedian", "wpm", "cpm", "accuracy", "coverage", "correctionRate", "activeWPM",
            "rhythmVariation", "hmmModelVersion", "modelBackend", "writingDuration", "thinkingDuration",
            "otherActivityDuration", "inactiveDuration", "featureFrameCount", "featureFramesData",
            "accuracyCharacterCount", "backspaceErrorCharacters", "spellingErrorCharacters",
            "grammarErrorCharacters", "accuracySampleCount"
        ]
        XCTAssertTrue(persistedNames.allSatisfy { name in
            prohibitedFragments.allSatisfy { !name.lowercased().contains($0) }
        })
    }
}
