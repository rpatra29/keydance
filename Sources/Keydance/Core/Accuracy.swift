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

    /// Passive typing has no reference text, so spelling/context accuracy is
    /// unknowable. This is retained for legacy benchmark display only.
    var accuracy: Double {
        guard characterCount > 0 else { return 1 }
        return max(0, 1 - Double(backspaceErrorCharacters) / Double(characterCount))
    }
}

struct AccuracyTotals: Sendable, Equatable {
    var characterCount = 0
    var backspaceErrorCharacters = 0
    var spellingErrorCharacters = 0
    var contextErrorCharacters = 0
    var sentenceCount = 0

    var errorCharacters: Int { backspaceErrorCharacters }

    var accuracy: Double {
        guard characterCount > 0 else { return 1 }
        return max(0, 1 - Double(backspaceErrorCharacters) / Double(characterCount))
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
    init() {}

    func evaluate(
        text: String,
        characterCount: Int,
        backspaceErrors: Int,
        id: Int,
        isComplete: Bool
    ) -> SentenceAccuracySample {
        return SentenceAccuracySample(
            id: id,
            characterCount: characterCount,
            backspaceErrorCharacters: backspaceErrors,
            spellingErrorCharacters: 0,
            contextErrorCharacters: 0,
            isComplete: isComplete
        )
    }

    static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.isLetter && character != "'"
        }.map { $0.lowercased() }
    }

    func spellingCandidates(in text: String) -> [String] {
        []
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
