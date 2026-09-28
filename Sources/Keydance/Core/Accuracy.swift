import Foundation

struct SentenceAccuracySample: Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let characterCount: Int
    let backspaceErrorCharacters: Int
    let spellingErrorCharacters: Int
    let contextErrorCharacters: Int
    let isComplete: Bool

    var errorCharacters: Int {
        backspaceErrorCharacters + spellingErrorCharacters + contextErrorCharacters
    }

    var accuracy: Double {
        guard characterCount > 0 else { return 1 }
        return max(0, 1 - Double(errorCharacters) / Double(characterCount))
    }
}

struct AccuracyTotals: Sendable, Equatable {
    var characterCount = 0
    var backspaceErrorCharacters = 0
    var spellingErrorCharacters = 0
    var contextErrorCharacters = 0
    var sentenceCount = 0

    var errorCharacters: Int {
        backspaceErrorCharacters + spellingErrorCharacters + contextErrorCharacters
    }

    var accuracy: Double {
        guard characterCount > 0 else { return 1 }
        return max(0, 1 - Double(errorCharacters) / Double(characterCount))
    }
}

struct AccuracyTrace: Sendable, Equatable {
    var currentText: String
    var currentTokens: [String]
    var spellingCandidates: [String]
    var backspaceErrors: Int
    var lastSample: SentenceAccuracySample?
}

struct SentenceAccuracyChecker {
    private let estimator: AccuracyEstimating

    init(estimator: AccuracyEstimating) {
        self.estimator = estimator
    }

    func evaluate(
        text: String,
        characterCount: Int,
        backspaceErrors: Int,
        id: Int,
        isComplete: Bool
    ) -> SentenceAccuracySample {
        let tokens = Self.tokens(in: text)
        let spellingErrors = tokens.reduce(0) { total, token in
            guard case let .likelyMisspelling(suggestion) = estimator.classify(token: token) else { return total }
            return total + DictionaryEstimator.editDistance(token, suggestion)
        }
        let contextErrors = Self.contextCorrections(in: tokens).reduce(0) { total, correction in
            total + DictionaryEstimator.editDistance(correction.from, correction.to)
        }
        return SentenceAccuracySample(
            id: id,
            characterCount: characterCount,
            backspaceErrorCharacters: backspaceErrors,
            spellingErrorCharacters: spellingErrors,
            contextErrorCharacters: contextErrors,
            isComplete: isComplete
        )
    }

    static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.isLetter && character != "'"
        }.map { $0.lowercased() }
    }

    func spellingCandidates(in text: String) -> [String] {
        Self.tokens(in: text).compactMap { token in
            guard case let .likelyMisspelling(suggestion) = estimator.classify(token: token) else { return nil }
            return "\(token) → \(suggestion)"
        }
    }

    private struct ContextCorrection {
        let from: String
        let to: String
    }

    /// High-confidence, local confusion rules. Unknown grammar is left alone
    /// rather than penalizing a writer for a guess we cannot justify.
    private static func contextCorrections(in tokens: [String]) -> [ContextCorrection] {
        var corrections: [ContextCorrection] = []
        for index in tokens.indices {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            let nextNext = index + 2 < tokens.count ? tokens[index + 2] : nil
            let previous = index > tokens.startIndex ? tokens[index - 1] : nil

            if token == "who", next == "is", nextNext == "the",
               index + 3 < tokens.count, tokens[index + 3] == "weather" {
                corrections.append(ContextCorrection(from: "who", to: "how"))
            } else if token == "your", next == "welcome" {
                corrections.append(ContextCorrection(from: "your", to: "you're"))
            } else if token == "its", next == "a" {
                corrections.append(ContextCorrection(from: "its", to: "it's"))
            } else if token == "to" && (next == "much" || next == "many") {
                corrections.append(ContextCorrection(from: "to", to: "too"))
            } else if token == "then",
                      ["more", "less", "rather", "other", "different"].contains(previous ?? "") {
                corrections.append(ContextCorrection(from: "then", to: "than"))
            }
        }
        return corrections
    }
}

struct SentenceAccuracyAccumulator {
    private let checker: SentenceAccuracyChecker
    private var text = ""
    private var insertedCharacterCount = 0
    private var backspaceErrors = 0
    private var nextID = 0
    private var lastSpellingCandidates: [String] = []

    private(set) var totals = AccuracyTotals()
    private(set) var samples: [SentenceAccuracySample] = []
    private(set) var lastSample: SentenceAccuracySample?

    init(checker: SentenceAccuracyChecker) {
        self.checker = checker
    }

    mutating func record(_ character: Character) {
        text.append(character)
        let isControl = character.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
        if !character.isNewline && !isControl {
            insertedCharacterCount += 1
        }
        if ".?!".contains(character) {
            finishCurrent(isComplete: true)
        }
    }

    mutating func recordDeletion() {
        guard !text.isEmpty else { return }
        text.removeLast()
        backspaceErrors += 1
    }

    mutating func finishPending() {
        finishCurrent(isComplete: false)
    }

    mutating func reset() {
        text = ""
        insertedCharacterCount = 0
        backspaceErrors = 0
        nextID = 0
        lastSpellingCandidates = []
        totals = AccuracyTotals()
        samples.removeAll(keepingCapacity: true)
        lastSample = nil
    }

    var trace: AccuracyTrace {
        AccuracyTrace(
            currentText: text,
            currentTokens: SentenceAccuracyChecker.tokens(in: text),
            spellingCandidates: text.isEmpty ? lastSpellingCandidates : checker.spellingCandidates(in: text),
            backspaceErrors: backspaceErrors,
            lastSample: lastSample
        )
    }

    private mutating func finishCurrent(isComplete: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            text = ""
            insertedCharacterCount = 0
            backspaceErrors = 0
            return
        }
        let sample = checker.evaluate(
            text: text,
            characterCount: insertedCharacterCount,
            backspaceErrors: backspaceErrors,
            id: nextID,
            isComplete: isComplete
        )
        lastSpellingCandidates = checker.spellingCandidates(in: text)
        lastSample = sample
        nextID += 1
        totals.characterCount += sample.characterCount
        totals.backspaceErrorCharacters += sample.backspaceErrorCharacters
        totals.spellingErrorCharacters += sample.spellingErrorCharacters
        totals.contextErrorCharacters += sample.contextErrorCharacters
        totals.sentenceCount += 1
        samples.append(sample)
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        text = ""
        insertedCharacterCount = 0
        backspaceErrors = 0
    }
}
