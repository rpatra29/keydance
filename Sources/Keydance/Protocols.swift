import Foundation

protocol AccuracyEstimating {
    func classify(token: String) -> TokenClassification
    func nearbyWords(for token: String) -> [String]
    func isLikelyGibberish(token: String) -> Bool
    func editDistance(from token: String, to suggestion: String) -> Int
}

extension AccuracyEstimating {
    func nearbyWords(for token: String) -> [String] { [] }
    func isLikelyGibberish(token: String) -> Bool { false }
    func editDistance(from token: String, to suggestion: String) -> Int {
        Levenshtein.distance(token, suggestion)
    }
}

enum TokenClassification: Equatable {
    case known
    case likelyMisspelling(suggestion: String, editDistance: Int)
    case unknown
}

enum Levenshtein {
    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}

protocol PauseClassifying {
    func classify(duration: TimeInterval, recentIntervals: [TimeInterval], previousCharacter: Character?) -> PauseKind?
}

struct AdaptivePauseClassifier: PauseClassifying {
    func classify(duration: TimeInterval, recentIntervals: [TimeInterval], previousCharacter: Character?) -> PauseKind? {
        guard duration >= AnalyticsMath.pauseThreshold(recentIntervals: recentIntervals) else { return nil }
        if let previousCharacter, ".?!".contains(previousCharacter) { return .betweenSentence }
        return .midSentence
    }
}
