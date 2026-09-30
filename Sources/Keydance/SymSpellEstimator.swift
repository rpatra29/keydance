import Foundation

struct VocabularyEntry: Sendable {
    let word: String
    let frequency: Int
}

/// A compact SymSpell dictionary for passive typing analysis.
///
/// SymSpell trades a little memory during initialization for fast lookups by
/// indexing every term's deletes. The bundled vocabulary is already ordered by
/// frequency, so that common words win when several candidates are equally
/// close to the typed token.
final class SymSpellEstimator: AccuracyEstimating {
    private static let prefixLength = 7

    private struct Term {
        let word: String
        let frequency: Int
    }

    private struct Candidate {
        let term: Term
        let distance: Int
    }

    private let maximumEditDistance: Int
    private let terms: [String: Term]
    private let deleteIndex: [String: [String]]

    init(entries: [VocabularyEntry], maximumEditDistance: Int = 2) {
        self.maximumEditDistance = max(1, maximumEditDistance)

        var uniqueTerms: [String: Term] = [:]
        for entry in entries {
            let word = Self.normalize(entry.word)
            guard Self.isWord(word) else { continue }

            let frequency = entry.frequency
            if let existing = uniqueTerms[word] {
                uniqueTerms[word] = Term(word: word, frequency: max(existing.frequency, frequency))
            } else {
                uniqueTerms[word] = Term(word: word, frequency: frequency)
            }
        }
        terms = uniqueTerms

        var index: [String: Set<String>] = [:]
        for term in uniqueTerms.values {
            for deleted in Self.generateDeletes(
                term.word,
                maximumEditDistance: self.maximumEditDistance,
                prefixLength: Self.prefixLength
            ) {
                index[deleted, default: []].insert(term.word)
            }
        }
        deleteIndex = index.mapValues { Array($0) }
    }

    func classify(token: String) -> TokenClassification {
        let token = Self.normalize(token)
        guard Self.isWord(token), token.count >= 2 else { return .unknown }
        guard terms[token] == nil else { return .known }

        let candidates = lookup(token)
        guard let best = candidates.first else { return .unknown }

        // One-edit matches are strong enough to call a typo. For two-edit
        // matches, require an unambiguous best result; otherwise an uncommon
        // but valid word can be incorrectly rewritten to a common one.
        if best.distance == 1 {
            return .likelyMisspelling(
                suggestion: best.term.word,
                editDistance: best.distance
            )
        }
        guard best.distance == 2, token.count >= 3 else { return .unknown }
        let tied = candidates.filter { $0.distance == best.distance }
        guard tied.count == 1 else { return .unknown }
        return .likelyMisspelling(
            suggestion: best.term.word,
            editDistance: best.distance
        )
    }

    func editDistance(from token: String, to suggestion: String) -> Int {
        Levenshtein.distance(token, suggestion)
    }

    func nearbyWords(for token: String) -> [String] {
        let token = Self.normalize(token)
        guard Self.isWord(token), token.count >= 2 else { return [] }
        return lookup(token)
            .filter { $0.term.word != token }
            .prefix(12)
            .map { $0.term.word }
    }

    func isLikelyGibberish(token: String) -> Bool {
        let token = Self.normalize(token)
        guard token.count >= 4, Self.isWord(token), terms[token] == nil else { return false }

        // A confident SymSpell suggestion means this is more likely a typo
        // than keyboard mashing. Ambiguous or unknown tokens still go through
        // the heuristics below; a large dictionary can contain unrelated
        // nearby words for random input.
        if case .likelyMisspelling = classify(token: token) { return false }

        let vowels = Set("aeiouy")
        let hasVowel = token.contains { vowels.contains($0) }
        var longestConsonantRun = 0
        var consonantRun = 0
        for character in token {
            if vowels.contains(character) {
                consonantRun = 0
            } else {
                consonantRun += 1
                longestConsonantRun = max(longestConsonantRun, consonantRun)
            }
        }

        let characters = Array(token)
        let hasTripleRepeat = characters.indices.dropLast(2).contains { index in
            characters[index] == characters[index + 1] && characters[index] == characters[index + 2]
        }
        let hasRepeatedChunk = (2...3).contains { chunkLength in
            guard characters.count >= chunkLength * 3 else { return false }
            let lastStart = characters.count - chunkLength * 3
            return (0...lastStart).contains { index in
                let chunk = Array(characters[index..<(index + chunkLength)])
                let next = index + chunkLength
                let following = Array(characters[next..<(next + chunkLength)])
                let final = next + chunkLength
                let repeated = Array(characters[final..<(final + chunkLength)])
                return chunk == following && chunk == repeated
            }
        }
        let hasRepeatedHalf = characters.count >= 6 && characters.count.isMultiple(of: 2) && {
            let chunkLength = characters.count / 2
            return Array(characters.prefix(chunkLength)) == Array(characters.dropFirst(chunkLength))
        }()

        return !hasVowel || longestConsonantRun >= 4 || hasTripleRepeat || hasRepeatedChunk || hasRepeatedHalf
    }

    private func lookup(_ token: String) -> [Candidate] {
        var possibleTerms = Set<String>()
        possibleTerms.formUnion(deleteIndex[token] ?? [])
        for deleted in Self.generateDeletes(
            token,
            maximumEditDistance: maximumEditDistance,
            prefixLength: Self.prefixLength
        ) {
            possibleTerms.formUnion(deleteIndex[deleted] ?? [])
        }

        return possibleTerms.compactMap { word in
            guard let term = terms[word] else { return nil }
            let distance = Self.editDistance(token, word, limit: maximumEditDistance)
            guard distance <= maximumEditDistance else { return nil }
            return Candidate(term: term, distance: distance)
        }
        .sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.term.frequency != $1.term.frequency { return $0.term.frequency > $1.term.frequency }
            return $0.term.word < $1.term.word
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
    }

    private static func isWord(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) }
    }

    private static func generateDeletes(
        _ word: String,
        maximumEditDistance: Int,
        prefixLength: Int
    ) -> Set<String> {
        var deletes = Set<String>()
        var current = Set([Array(word.utf8)])

        for _ in 0..<maximumEditDistance {
            var next = Set<[UInt8]>()
            for characters in current {
                guard !characters.isEmpty else { continue }
                for index in 0..<min(characters.count, prefixLength) {
                    var deleted = characters
                    deleted.remove(at: index)
                    let value = String(decoding: deleted, as: UTF8.self)
                    if deletes.insert(value).inserted {
                        next.insert(deleted)
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return deletes
    }

    /// Levenshtein distance. SymSpell's delete index narrows the candidates;
    /// this verifies each candidate without scanning the full vocabulary.
    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }

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
