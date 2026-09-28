import CoreML
import Foundation

struct TemporalPrediction: Sendable {
    var state: TypingBehaviorState
    var probabilities: [String: Double]
    var sentenceState: SentenceState
    var activityState: ActivityState
    var confidence: Double
    var isProvisional: Bool
}

struct TextModelQualitySummary: Sendable {
    let validationAccuracy: Double
    let perClassRecall: [String: Double]
    let validationSamples: Int
    let validationParticipants: Int
    let validationSource: String
    let hasWeakLabels: Bool
    let numericMean: [Double]
    let numericStd: [Double]

    var minimumClassRecall: Double {
        perClassRecall.values.min() ?? 0
    }

    static func load() -> TextModelQualitySummary? {
        let url = Bundle.main.url(forResource: "SessionTextTransformer.metadata", withExtension: "json")
            ?? Bundle.module.url(forResource: "SessionTextTransformer.metadata", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        return TextModelQualitySummary(
            validationAccuracy: metadata.validationAccuracy,
            perClassRecall: metadata.perClassRecall,
            validationSamples: metadata.validationSummary.samples,
            validationParticipants: metadata.validationSummary.participants,
            validationSource: metadata.validationSummary.sources?.keys.sorted().joined(separator: ", ") ?? "unknown",
            hasWeakLabels: metadata.validationSummary.labelQuality?.keys.contains(where: { $0.hasPrefix("weak_") || $0 == "boundary_proxy" }) ?? false,
            numericMean: metadata.numericMean ?? Array(repeating: 0, count: TextModelSchema.numericFeatureNames.count),
            numericStd: metadata.numericStd ?? Array(repeating: 1, count: TextModelSchema.numericFeatureNames.count)
        )
    }

    private struct Metadata: Decodable {
        let validationAccuracy: Double
        let perClassRecall: [String: Double]
        let validationSummary: ValidationSummary
        let numericMean: [Double]?
        let numericStd: [Double]?

        enum CodingKeys: String, CodingKey {
            case validationAccuracy = "validation_accuracy"
            case perClassRecall = "per_class_recall"
            case validationSummary = "validation_summary"
            case numericMean = "numeric_mean"
            case numericStd = "numeric_std"
        }
    }

    private struct ValidationSummary: Decodable {
        let samples: Int
        let participants: Int
        let sources: [String: Int]?
        let labelQuality: [String: Int]?

        enum CodingKeys: String, CodingKey {
            case samples
            case participants
            case sources
            case labelQuality = "label_quality"
        }
    }
}

enum WritingState: String, Codable, CaseIterable, Sendable {
    case writing
    case midThought
    case sentenceComplete
    case finished
    case otherActivity

    var temporalState: TypingBehaviorState {
        switch self {
        case .writing: .writing
        case .midThought, .sentenceComplete: .thinking
        case .finished: .inactive
        case .otherActivity: .otherActivity
        }
    }
}

enum TextModelSchema {
    static let version = 1
    static let maxTokens = 128
    static let vocabularySize = 8_192
    static let labels = WritingState.allCases.map(\.rawValue)
    static let numericFeatureNames = [
        "events_per_second",
        "printable_per_second",
        "silence_duration",
        "sentence_character_count",
        "word_count",
        "correction_count",
        "printable_ratio",
        "non_typing_ratio"
    ]
}

struct TextAwareModelInput: Sendable, Equatable {
    static let modelName = "SessionTextTransformer"

    var schemaVersion: Int
    var tokenIDs: [Int32]
    var wordDurations: [Float]
    var wordGaps: [Float]
    var numericFeatures: [Float]
    var context: WritingContextSnapshot

    init(frame: SessionWindowObservation, context: WritingContextSnapshot) {
        schemaVersion = TextModelSchema.version
        let tokens = Array(context.tokens.suffix(TextModelSchema.maxTokens))
        tokenIDs = TextModelTokenizer.encode(tokens)
        wordDurations = Array(context.wordTimings.suffix(TextModelSchema.maxTokens).map { Float($0.duration) })
        wordGaps = Array(context.wordTimings.suffix(TextModelSchema.maxTokens).map { Float($0.gapBefore) })
        wordDurations = Self.pad(wordDurations)
        wordGaps = Self.pad(wordGaps)
        numericFeatures = [
            Float(frame.eventsPerSecond),
            Float(Double(frame.printableCount) / max(frame.duration, 0.001)),
            Float(context.secondsSinceLastCharacter ?? frame.duration),
            Float(context.currentSentenceCharacterCount),
            Float(context.wordCount),
            Float(context.correctionCount),
            Float(frame.printableRatio),
            Float(frame.otherKeyRatio)
        ]
        self.context = context
    }

    private static func pad(_ values: [Float]) -> [Float] {
        if values.count >= TextModelSchema.maxTokens {
            return Array(values.suffix(TextModelSchema.maxTokens))
        }
        return Array(repeating: 0, count: TextModelSchema.maxTokens - values.count) + values
    }
}

struct WritingStatePrediction: Sendable {
    var state: WritingState
    var probabilities: [String: Double]

    var confidence: Double { probabilities.values.max() ?? 0 }

    var sentenceState: SentenceState {
        switch state {
        case .midThought: .incomplete
        case .sentenceComplete: .likelyComplete
        default: .uncertain
        }
    }

    var activityState: ActivityState {
        switch state {
        case .writing: .activeTyping
        case .midThought, .sentenceComplete: .thinking
        case .finished: .finished
        case .otherActivity: .uncertain
        }
    }

    var temporalPrediction: TemporalPrediction {
        let writing = probabilities[WritingState.writing.rawValue] ?? 0
        let midThought = probabilities[WritingState.midThought.rawValue] ?? 0
        let sentenceComplete = probabilities[WritingState.sentenceComplete.rawValue] ?? 0
        let finished = probabilities[WritingState.finished.rawValue] ?? 0
        let otherActivity = probabilities[WritingState.otherActivity.rawValue] ?? 0
        let mapped = [
            TypingBehaviorState.writing.rawValue: writing,
            TypingBehaviorState.thinking.rawValue: midThought + sentenceComplete,
            TypingBehaviorState.otherActivity.rawValue: otherActivity,
            TypingBehaviorState.inactive.rawValue: finished
        ]
        return TemporalPrediction(
            state: state.temporalState,
            probabilities: mapped,
            sentenceState: sentenceState,
            activityState: activityState,
            confidence: confidence,
            isProvisional: state == .midThought || state == .sentenceComplete || state == .finished
        )
    }
}

/// Hash-based tokenizer keeps runtime input fixed-size without shipping raw
/// text to Core ML. Collisions are acceptable for the first model iteration;
/// a trained vocabulary can replace this tokenizer without changing the model
/// input shape.
enum TextModelTokenizer {
    static func encode(_ tokens: [String]) -> [Int32] {
        let encoded = tokens.map { Int32(stableHash($0.lowercased()) % UInt64(TextModelSchema.vocabularySize - 2) + 2) }
        if encoded.count >= TextModelSchema.maxTokens {
            return Array(encoded.suffix(TextModelSchema.maxTokens))
        }
        return Array(repeating: 0, count: TextModelSchema.maxTokens - encoded.count) + encoded
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

final class SessionTextModelRuntime {
    static let shared = SessionTextModelRuntime()

    private(set) var status: String
    let quality: TextModelQualitySummary?
    private let model: MLModel?

    private init() {
        quality = TextModelQualitySummary.load()
        do {
            let url = try Self.locateModel()
            model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            status = "Core ML text model loaded"
        } catch {
            model = nil
            status = "No trained text model installed; using text-aware fallback"
        }
    }

    func predict(input: TextAwareModelInput) -> WritingStatePrediction? {
        guard let model else { return nil }
        do {
            let tokenIDs = try MLMultiArray(shape: [1, NSNumber(value: TextModelSchema.maxTokens)], dataType: .int32)
            let durations = try MLMultiArray(shape: [1, NSNumber(value: TextModelSchema.maxTokens)], dataType: .float32)
            let gaps = try MLMultiArray(shape: [1, NSNumber(value: TextModelSchema.maxTokens)], dataType: .float32)
            let numeric = try MLMultiArray(shape: [1, NSNumber(value: TextModelSchema.numericFeatureNames.count)], dataType: .float32)
            for index in 0..<TextModelSchema.maxTokens {
                tokenIDs[index] = NSNumber(value: input.tokenIDs[index])
                durations[index] = NSNumber(value: input.wordDurations[index])
                gaps[index] = NSNumber(value: input.wordGaps[index])
            }
            let mean = quality?.numericMean ?? Array(repeating: 0, count: input.numericFeatures.count)
            let standardDeviation = quality?.numericStd ?? Array(repeating: 1, count: input.numericFeatures.count)
            for index in 0..<input.numericFeatures.count {
                let divisor = max(standardDeviation[index], 1e-5)
                numeric[index] = NSNumber(value: (Double(input.numericFeatures[index]) - mean[index]) / divisor)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "token_ids": MLFeatureValue(multiArray: tokenIDs),
                "word_durations": MLFeatureValue(multiArray: durations),
                "word_gaps": MLFeatureValue(multiArray: gaps),
                "numeric_features": MLFeatureValue(multiArray: numeric)
            ])
            let result = try model.prediction(from: provider)
            guard let logits = result.featureValue(for: "logits")?.multiArrayValue,
                  logits.count == WritingState.allCases.count else { return nil }
            let values = (0..<logits.count).map { logits[$0].doubleValue }
            let peak = values.max() ?? 0
            let weights = values.map { exp($0 - peak) }
            let total = max(weights.reduce(0, +), 1e-12)
            let probabilities = Dictionary(uniqueKeysWithValues: zip(WritingState.allCases, weights).map {
                ($0.0.rawValue, $0.1 / total)
            })
            let state = WritingState.allCases.enumerated().max {
                weights[$0.offset] < weights[$1.offset]
            }?.element ?? .finished
            return WritingStatePrediction(state: state, probabilities: probabilities)
        } catch {
            return nil
        }
    }

    private static func locateModel() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["KEYDANCE_TEXT_MODEL"] {
            let source = URL(fileURLWithPath: override)
            if source.pathExtension == "mlmodelc" { return source }
            return try MLModel.compileModel(at: source)
        }
        if let bundled = Bundle.main.url(forResource: TextAwareModelInput.modelName, withExtension: "mlmodelc") {
            return bundled
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

struct TextAwareFallbackClassifier {
    func infer(input: TextAwareModelInput) -> WritingStatePrediction {
        let context = input.context
        let frame = input.numericFeatures
        let eventRate = Double(frame[0])
        let silence = Double(frame[2])
        let printableRatio = Double(frame[6])
        let nonTypingRatio = Double(frame[7])

        let state: WritingState
        if nonTypingRatio >= 0.55, eventRate > 0 {
            state = .otherActivity
        } else if silence >= 90, eventRate == 0 {
            state = .finished
        } else if printableRatio >= 0.35 && eventRate >= 0.35 {
            state = .writing
        } else if context.endsWithSentencePunctuation && silence >= 1.2 {
            state = .sentenceComplete
        } else if context.hasUnfinishedSentence && silence >= 1.2 {
            state = .midThought
        } else if !context.text.isEmpty && silence >= 0.8 {
            state = .midThought
        } else {
            state = .writing
        }

        var probabilities = Dictionary(uniqueKeysWithValues: WritingState.allCases.map { ($0.rawValue, 0.03) })
        probabilities[state.rawValue] = 0.88
        return WritingStatePrediction(state: state, probabilities: probabilities)
    }
}
