import Foundation

/// In-memory text and timing context for one active session.
///
/// This type is intentionally not Codable. Raw text must not cross the runtime
/// boundary into persisted analytics, logs, or training records by accident.
struct WritingContextSnapshot: Sendable, Equatable {
    /// Timing-only sentence boundaries. This intentionally carries no text.
    struct SentenceTiming: Sendable, Equatable {
        var characterTimestamps: [Date]
        var startedAt: Date
        var endedAt: Date
        var timedDuration: TimeInterval
        var isComplete: Bool

        var characterCount: Int { characterTimestamps.count }
    }

    struct WordTiming: Sendable, Equatable {
        var text: String
        var duration: TimeInterval
        var gapBefore: TimeInterval
    }

    var capturedAt: Date
    var text: String
    var tokens: [String]
    var wordTimings: [WordTiming]
    var characterCount: Int
    var wordCount: Int
    var correctionCount: Int
    var completedSentenceCount: Int
    var currentSentenceCharacterCount: Int
    var hasUnfinishedSentence: Bool
    var endsWithSentencePunctuation: Bool
    var secondsSinceLastCharacter: TimeInterval?
    var sentenceTimings: [SentenceTiming]

    static func empty(at date: Date) -> WritingContextSnapshot {
        WritingContextSnapshot(
            capturedAt: date,
            text: "",
            tokens: [],
            wordTimings: [],
            characterCount: 0,
            wordCount: 0,
            correctionCount: 0,
            completedSentenceCount: 0,
            currentSentenceCharacterCount: 0,
            hasUnfinishedSentence: false,
            endsWithSentencePunctuation: false,
            secondsSinceLastCharacter: nil,
            sentenceTimings: []
        )
    }
}

struct WritingContextBuffer: Sendable {
    static let maxCharacters = 512
    static let maxWords = 128

    private struct TimedCharacter: Sendable, Equatable {
        var character: Character
        var at: Date
    }

    private var characters: [TimedCharacter] = []
    private var timingBreaks: [Date] = []
    private var correctionCount = 0

    mutating func recordPrintable(_ character: Character, at date: Date) {
        append(TimedCharacter(character: character, at: date))
    }

    mutating func recordBoundary(_ character: Character, at date: Date) {
        append(TimedCharacter(character: character, at: date))
    }

    mutating func recordDeletion() {
        guard !characters.isEmpty else { return }
        characters.removeLast()
        correctionCount += 1
    }

    /// Ends the current timed typing burst without discarding the in-memory
    /// sentence context. The next typing event can resume the same sentence,
    /// but the inactive gap will not inflate its raw WPM.
    mutating func recordTimingBreak(at date: Date) {
        guard timingBreaks.last != date else { return }
        timingBreaks.append(date)
        if timingBreaks.count > Self.maxCharacters {
            timingBreaks.removeFirst(timingBreaks.count - Self.maxCharacters)
        }
    }

    func snapshot(at date: Date) -> WritingContextSnapshot {
        let words = makeWordTimings()
        let sentenceTimings = makeSentenceTimings(at: date)
        let text = String(characters.map(\.character))
        let lastMeaningful = characters.last(where: { !$0.character.isWhitespace })?.character
        let endsWithPunctuation = lastMeaningful.map { ".?!".contains($0) } ?? false
        let lastSentenceStart = text.lastIndex(where: { ".?!".contains($0) }).map { text.index(after: $0) }
        let currentSentence = lastSentenceStart.map { String(text[$0...]) } ?? text
        let currentSentenceCount = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines).count

        return WritingContextSnapshot(
            capturedAt: date,
            text: text,
            tokens: words.suffix(Self.maxWords).map(\.text),
            wordTimings: Array(words.suffix(Self.maxWords)),
            characterCount: characters.count,
            wordCount: words.count,
            correctionCount: correctionCount,
            completedSentenceCount: text.reduce(into: 0) { count, character in
                if ".?!".contains(character) { count += 1 }
            },
            currentSentenceCharacterCount: currentSentenceCount,
            hasUnfinishedSentence: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !endsWithPunctuation,
            endsWithSentencePunctuation: endsWithPunctuation,
            secondsSinceLastCharacter: characters.last.map { max(0, date.timeIntervalSince($0.at)) },
            sentenceTimings: sentenceTimings
        )
    }

    mutating func reset() {
        characters.removeAll(keepingCapacity: true)
        timingBreaks.removeAll(keepingCapacity: true)
        correctionCount = 0
    }

    private mutating func append(_ item: TimedCharacter) {
        characters.append(item)
        if characters.count > Self.maxCharacters {
            characters.removeFirst(characters.count - Self.maxCharacters)
        }
    }

    private func makeWordTimings() -> [WritingContextSnapshot.WordTiming] {
        var words: [[TimedCharacter]] = []
        var current: [TimedCharacter] = []

        func finish(_ value: [TimedCharacter], into words: inout [[TimedCharacter]]) {
            guard !value.isEmpty else { return }
            words.append(value)
        }

        for item in characters {
            if item.character.isWhitespace {
                finish(current, into: &words)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(item)
            }
        }
        finish(current, into: &words)

        var previousEnd: Date?
        return words.map { word in
            let first = word[0]
            let last = word[word.count - 1]
            let duration = max(0, last.at.timeIntervalSince(first.at))
            let gap = previousEnd.map { max(0, first.at.timeIntervalSince($0)) } ?? 0
            previousEnd = last.at
            return .init(text: String(word.map(\.character)), duration: duration, gapBefore: gap)
        }
    }

    private func makeSentenceTimings(at date: Date) -> [WritingContextSnapshot.SentenceTiming] {
        var sentences: [WritingContextSnapshot.SentenceTiming] = []
        var current: [TimedCharacter] = []

        func appendComplete(_ characters: [TimedCharacter], into sentences: inout [WritingContextSnapshot.SentenceTiming]) {
            guard let first = characters.first, let last = characters.last else { return }
            sentences.append(.init(
                characterTimestamps: characters.map(\.at),
                startedAt: first.at,
                endedAt: last.at,
                timedDuration: timedDuration(for: characters),
                isComplete: true
            ))
        }

        for item in characters {
            // Spaces after a completed sentence belong to neither sentence.
            if current.isEmpty, item.character.isWhitespace { continue }
            current.append(item)
            if ".?!".contains(item.character) {
                appendComplete(current, into: &sentences)
                current.removeAll(keepingCapacity: true)
            }
        }

        if let first = current.first {
            sentences.append(.init(
                characterTimestamps: current.map(\.at),
                startedAt: first.at,
                endedAt: current.last?.at ?? date,
                timedDuration: timedDuration(for: current),
                isComplete: false
            ))
        }
        return sentences
    }

    private func timedDuration(for characters: [TimedCharacter]) -> TimeInterval {
        guard characters.count > 1 else { return 0 }
        return zip(characters, characters.dropFirst()).reduce(0) { total, pair in
            let previous = pair.0
            let current = pair.1
            // A break at the previous character stops the gap that follows
            // it; a break exactly at the current character must not erase the
            // interval that produced that character.
            let interrupted = timingBreaks.contains { $0 >= previous.at && $0 < current.at }
            return total + (interrupted ? 0 : max(0, current.at.timeIntervalSince(previous.at)))
        }
    }
}
