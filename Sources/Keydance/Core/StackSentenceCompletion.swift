import Foundation

/// A small, explainable completion layer over the in-memory writing stack.
///
/// The Core ML model supplies a noisy prior. This layer adds compositional
/// evidence from the current sentence and treats punctuation as strong evidence,
/// not as the only way to decide that a sentence is complete.
struct StackSentenceCompletionPrediction: Equatable, Sendable {
    var state: SentenceState
    var completionScore: Double
    var lexicalScore: Double
    var punctuationScore: Double
    var modelScore: Double
    var reason: String
}

/// Live-only explanation of one inference. This is intentionally not Codable
/// and is never included in persisted session records.
struct StackModelInterpretation: Equatable, Sendable {
    var text: String
    var currentSentence: String
    var tokens: [String]
    var numericFeatures: [String: Double]
    var rawState: WritingState
    var rawProbabilities: [String: Double]
    var completion: StackSentenceCompletionPrediction

    var rawProbabilityLine: String {
        WritingState.allCases.map { state in
            "\(state.rawValue) \(String(format: "%.1f%%", (rawProbabilities[state.rawValue] ?? 0) * 100))"
        }.joined(separator: " · ")
    }

    var featureLine: String {
        TextModelSchema.numericFeatureNames.map { name in
            "\(name)=\(String(format: "%.2f", numericFeatures[name] ?? 0))"
        }.joined(separator: " · ")
    }
}

struct StackSentenceCompletionClassifier: Sendable {
    private static let continuationWords: Set<String> = [
        "about", "after", "although", "and", "as", "at", "because", "before", "but",
        "by", "can", "could", "did", "does", "for", "from", "had", "has", "have",
        "if", "in", "is", "of", "on", "or", "that", "the", "to", "was", "were",
        "when", "where", "whether", "while", "which", "who", "whom", "whose", "why", "with",
        "would", "should", "will", "might", "must", "need", "want"
    ]

    private static let leadingFragmentWords: Set<String> = [
        "about", "after", "although", "and", "as", "at", "because", "before", "but",
        "during", "for", "from", "if", "in", "on", "or", "since", "that", "through",
        "to", "unless", "until", "when", "while", "with"
    ]

    private static let standaloneWords: Set<String> = [
        "bye", "done", "hello", "hey", "no", "okay", "sure", "thanks", "yes"
    ]

    func predict(
        context: WritingContextSnapshot,
        modelState: SentenceState = .uncertain,
        silence: TimeInterval,
        pauseThreshold: TimeInterval
    ) -> StackSentenceCompletionPrediction {
        guard context.characterCount > 0 else {
            return .init(
                state: .uncertain, completionScore: 0.5, lexicalScore: 0.5,
                punctuationScore: 0, modelScore: 0.5, reason: "no text"
            )
        }

        let words = currentSentenceWords(from: context.text)
        let lastWord = words.last ?? ""
        let lexical = lexicalScore(words: words, context: context)
        let punctuation = context.endsWithSentencePunctuation ? 1.0 : 0.0
        let model = modelState == .likelyComplete ? 1.0 : modelState == .incomplete ? 0.0 : 0.5

        // Punctuation is a decisive local signal, but the model and lexical
        // stack evidence still remain visible in the score for diagnostics.
        let score: Double
        let reason: String
        if context.endsWithSentencePunctuation {
            score = 0.97
            reason = "terminal punctuation"
        } else {
            score = min(0.98, max(0.02, lexical * 0.82 + model * 0.08 + pauseEvidence(silence: silence, threshold: pauseThreshold) * 0.10))
            reason = lexicalReason(words: words, lexicalScore: lexical, lastWord: lastWord)
        }

        let state: SentenceState
        if score >= 0.67 && (context.endsWithSentencePunctuation || silence >= pauseThreshold) {
            state = .likelyComplete
        } else if lexical <= 0.32 || score <= 0.38 {
            state = .incomplete
        } else {
            state = .uncertain
        }

        return .init(
            state: state, completionScore: score, lexicalScore: lexical,
            punctuationScore: punctuation, modelScore: model, reason: reason
        )
    }

    private func lexicalScore(words: [String], context: WritingContextSnapshot) -> Double {
        guard let last = words.last else { return 0.5 }
        if words.count == 1 {
            return Self.standaloneWords.contains(last) ? 0.82 : 0.5
        }
        if Self.leadingFragmentWords.contains(words[0]) {
            return 0.30
        }
        if Self.continuationWords.contains(last) {
            return 0.18
        }
        if words.count >= 4 && context.currentSentenceCharacterCount >= 18 {
            return 0.78
        }
        return words.count >= 3 ? 0.72 : 0.60
    }

    private func currentSentenceWords(from text: String) -> [String] {
        let start = text.lastIndex(where: { ".?!".contains($0) }).map { text.index(after: $0) } ?? text.startIndex
        return text[start...]
            .split(whereSeparator: { $0.isWhitespace })
            .map { Self.normalizedWord(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func pauseEvidence(silence: TimeInterval, threshold: TimeInterval) -> Double {
        guard threshold > 0 else { return 0.5 }
        return min(1, max(0, silence / threshold))
    }

    private func lexicalReason(words: [String], lexicalScore: Double, lastWord: String) -> String {
        if let first = words.first, Self.leadingFragmentWords.contains(first) {
            return "leading fragment"
        }
        if Self.continuationWords.contains(lastWord) {
            return "continuation word: \(lastWord)"
        }
        return lexicalScore >= 0.67 ? "closed lexical shape" : "ambiguous lexical shape"
    }

    private static func normalizedWord(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
