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

    /// Passive typing has no reference text, so this remains a local estimate
    /// based on corrections and dictionary-backed spelling signals.
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
    var spellingErrorWords = 0
    var contextErrorWords = 0
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
    var contextCandidates: [String]
    var spellingErrorCharacters: Int
    var contextErrorCharacters: Int
    var backspaceErrors: Int
    var lastSample: SentenceAccuracySample?
}

struct SentenceAccuracyChecker {
    private struct Candidate {
        let token: String
        let errorDistance: Int
    }

    private let estimator: AccuracyEstimating?
    private let contextualScorer: ContextualAccuracyScorer?

    init(
        estimator: AccuracyEstimating? = nil,
        contextualScorer: ContextualAccuracyScorer? = .shared
    ) {
        self.estimator = estimator
        self.contextualScorer = contextualScorer
    }

    func evaluate(
        text: String,
        characterCount: Int,
        backspaceErrors: Int,
        id: Int,
        isComplete: Bool
    ) -> SentenceAccuracySample {
        let analysis = candidateSets(in: text, scanAllTokens: true)
        let spellingCharacters = analysis.spelling.reduce(0) { total, candidate in total + candidate.errorDistance }
        let contextCharacters = analysis.context.reduce(0) { total, candidate in total + candidate.errorDistance }
        return SentenceAccuracySample(
            id: id,
            characterCount: characterCount,
            backspaceErrorCharacters: backspaceErrors,
            spellingErrorCharacters: spellingCharacters,
            contextErrorCharacters: contextCharacters,
            isComplete: isComplete
        )
    }

    static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.isLetter && character != "'"
        }.map { $0.lowercased() }
    }

    func spellingCandidates(in text: String) -> [String] {
        candidateSets(in: text, scanAllTokens: false).spelling.map(\.token)
    }

    func spellingErrorCharacters(in text: String) -> Int {
        candidateSets(in: text, scanAllTokens: false).spelling.reduce(0) { $0 + $1.errorDistance }
    }

    func contextCandidates(in text: String) -> [String] {
        candidateSets(in: text, scanAllTokens: false).context.map(\.token)
    }

    func contextErrorCharacters(in text: String) -> Int {
        candidateSets(in: text, scanAllTokens: false).context.reduce(0) { $0 + $1.errorDistance }
    }

    private func candidateSets(in text: String, scanAllTokens: Bool) -> (spelling: [Candidate], context: [Candidate]) {
        let tokens = Self.tokens(in: text)
        guard !tokens.isEmpty else { return ([], []) }
        let spelling = tokens.compactMap { token -> Candidate? in
            guard let estimator else { return nil }
            switch estimator.classify(token: token) {
            case let .likelyMisspelling(_, editDistance):
                return Candidate(token: token, errorDistance: editDistance)
            case .known:
                return nil
            case .unknown:
                return estimator.isLikelyGibberish(token: token)
                    ? Candidate(token: token, errorDistance: token.count)
                    : nil
            }
        }
        guard let contextualScorer, contextualScorer.isLoaded, tokens.count >= 2 else {
            return (spelling, [])
        }

        // Do not score a word while it is still being typed. For the live
        // trace, score only the newest completed word; a finished sentence is
        // scanned end-to-end once so earlier contextual substitutions count.
        var completedTokens = tokens
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last.isLetter || last == "'" {
            completedTokens.removeLast()
        }
        guard completedTokens.count >= 2 else { return (spelling, []) }
        let indexes: [Int] = scanAllTokens
            ? Array(completedTokens.indices)
            : [completedTokens.index(before: completedTokens.endIndex)]
        let context = indexes.compactMap { index -> Candidate? in
            let token = completedTokens[index]
            guard token.count >= 2, !spelling.contains(where: { $0.token == token }) else { return nil }
            let prefix = Array(completedTokens.prefix(index + 1))
            guard let actualScore = contextualScorer.score(for: prefix) else {
                return nil
            }
            let bestAlternative = estimator?.nearbyWords(for: token).compactMap { alternative -> (String, Double)? in
                var replacement = prefix
                replacement[index] = alternative
                guard let score = contextualScorer.score(for: replacement) else { return nil }
                return (alternative, score)
            }.max { $0.1 < $1.1 }
            guard let bestAlternative, bestAlternative.1 - actualScore >= 0.18 else { return nil }
            let distance = estimator?.editDistance(from: token, to: bestAlternative.0) ?? token.count
            return Candidate(token: token, errorDistance: max(1, distance))
        }
        return (spelling, context)
    }

}

struct SentenceAccuracyAccumulator {
    private let checker: SentenceAccuracyChecker
    private var text = ""
    private var insertedCharacterCount = 0
    private var backspaceErrors = 0
    private var nextID = 0
    private var lastSpellingCandidates: [String] = []
    private var lastContextCandidates: [String] = []
    private var lastSpellingErrorCharacters = 0
    private var lastContextErrorCharacters = 0

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
        lastContextCandidates = []
        lastSpellingErrorCharacters = 0
        lastContextErrorCharacters = 0
        totals = AccuracyTotals()
        samples.removeAll(keepingCapacity: true)
        lastSample = nil
    }

    var trace: AccuracyTrace {
        AccuracyTrace(
            currentText: text,
            currentTokens: SentenceAccuracyChecker.tokens(in: text),
            spellingCandidates: text.isEmpty ? lastSpellingCandidates : checker.spellingCandidates(in: text),
            contextCandidates: text.isEmpty ? lastContextCandidates : checker.contextCandidates(in: text),
            spellingErrorCharacters: text.isEmpty ? lastSpellingErrorCharacters : checker.spellingErrorCharacters(in: text),
            contextErrorCharacters: text.isEmpty ? lastContextErrorCharacters : checker.contextErrorCharacters(in: text),
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
        lastContextCandidates = checker.contextCandidates(in: text)
        lastSpellingErrorCharacters = checker.spellingErrorCharacters(in: text)
        lastContextErrorCharacters = checker.contextErrorCharacters(in: text)
        lastSample = sample
        nextID += 1
        totals.characterCount += sample.characterCount
        totals.backspaceErrorCharacters += sample.backspaceErrorCharacters
        totals.spellingErrorCharacters += sample.spellingErrorCharacters
        totals.contextErrorCharacters += sample.contextErrorCharacters
        totals.spellingErrorWords += lastSpellingCandidates.count
        totals.contextErrorWords += lastContextCandidates.count
        totals.sentenceCount += 1
        samples.append(sample)
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        text = ""
        insertedCharacterCount = 0
        backspaceErrors = 0
    }
}
