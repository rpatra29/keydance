import Foundation

enum WordWhitelist {
    private static let storageKey = "insightWhitelistedWords"

    static var words: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: storageKey) ?? []).map(normalize))
    }

    static func contains(_ word: String) -> Bool {
        words.contains(normalize(word))
    }

    static func add(_ word: String) {
        var updated = words
        let value = normalize(word)
        guard !value.isEmpty else { return }
        updated.insert(value)
        UserDefaults.standard.set(Array(updated).sorted(), forKey: storageKey)
    }

    static func remove(_ word: String) {
        var updated = words
        updated.remove(normalize(word))
        UserDefaults.standard.set(Array(updated).sorted(), forKey: storageKey)
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
