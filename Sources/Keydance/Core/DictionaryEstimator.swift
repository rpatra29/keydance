import Foundation

final class DictionaryEstimator: AccuracyEstimating {
    private let words: Set<String>
    private let wordsByLength: [Int: [String]]

    init(words: [String]) {
        self.words = Set(words)
        self.wordsByLength = Dictionary(grouping: words, by: \.count)
    }

    func classify(token: String) -> TokenClassification {
        let token = token.lowercased()
        guard token.count >= 2, token.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return .unknown }
        if words.contains(token) { return .known }
        let droppedTrailingCharacter = String(token.dropLast())
        if droppedTrailingCharacter.count >= 2, words.contains(droppedTrailingCharacter) {
            return .likelyMisspelling(suggestion: droppedTrailingCharacter)
        }
        let candidates = ((token.count - 1)...(token.count + 1)).flatMap { wordsByLength[$0] ?? [] }
        let matches = candidates.filter { Self.editDistance(token, $0, limit: 1) == 1 }
        return matches.count == 1 ? .likelyMisspelling(suggestion: matches[0]) : .unknown
    }

    static func editDistance(_ lhs: String, _ rhs: String, limit: Int = .max) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for (j, right) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
                rowMinimum = min(rowMinimum, current[j + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
