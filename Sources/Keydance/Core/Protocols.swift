import Foundation

protocol AccuracyEstimating {
    func classify(token: String) -> TokenClassification
}

enum TokenClassification: Equatable {
    case known
    case likelyMisspelling(suggestion: String)
    case unknown
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
