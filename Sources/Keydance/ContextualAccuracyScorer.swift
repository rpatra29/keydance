import Foundation

struct ContextualAccuracyPrediction: Sendable, Equatable {
    let probability: Double

    /// The app uses relative scores against nearby dictionary alternatives;
    /// this is only a diagnostic low-confidence signal.
    var isLowConfidence: Bool { probability < 0.15 }
}

/// Small native inference runtime for the recovered ContextualAccuracyScorer
/// checkpoint. The app ships the float weights in a compact resource instead
/// of trying to deserialize PyTorch state directly at runtime.
final class ContextualAccuracyScorer: @unchecked Sendable {
    static let shared = ContextualAccuracyScorer()

    private static let sequenceLength = 48
    private static let vocabularySize = 8_192
    private static let width = 64
    private static let heads = 4
    private static let headWidth = width / heads
    private static let layerCount = 2

    private let tensors: [String: Tensor]

    private init() {
        tensors = Self.loadWeights() ?? [:]
    }

    var isLoaded: Bool { !tensors.isEmpty }

    func score(for tokens: [String]) -> Double? {
        guard isLoaded, tokens.count >= 2 else { return nil }
        let values = forward(tokenIDs: Self.tokenIDs(for: tokens))
        guard let logit = values.first, logit.isFinite else { return nil }
        return 1 / (1 + exp(-Double(logit)))
    }

    func prediction(for tokens: [String]) -> ContextualAccuracyPrediction? {
        guard let probability = score(for: tokens) else { return nil }
        return ContextualAccuracyPrediction(probability: probability)
    }

    private func forward(tokenIDs: [Int]) -> [Float] {
        let embedding = tensors["embedding.weight"]!.values
        let position = tensors["position"]!.values
        var encoded = Array(repeating: Float.zero, count: Self.sequenceLength * Self.width)

        for index in 0..<Self.sequenceLength {
            let token = min(max(tokenIDs[index], 0), Self.vocabularySize - 1)
            let sourceOffset = token * Self.width
            let destinationOffset = index * Self.width
            for feature in 0..<Self.width {
                encoded[destinationOffset + feature] = embedding[sourceOffset + feature]
                    + position[destinationOffset + feature]
            }
        }

        for layer in 0..<Self.layerCount {
            encoded = encoderLayer(encoded, layer: layer)
        }

        let finalOffset = (Self.sequenceLength - 1) * Self.width
        let finalVector = Array(encoded[finalOffset..<(finalOffset + Self.width)])
        let normalized = layerNorm(
            finalVector,
            gamma: tensors["classifier.0.weight"]!.values,
            beta: tensors["classifier.0.bias"]!.values
        )
        return linear(
            normalized,
            weight: tensors["classifier.1.weight"]!.values,
            bias: tensors["classifier.1.bias"]!.values,
            outputWidth: 1
        )
    }

    private func encoderLayer(_ input: [Float], layer: Int) -> [Float] {
        let prefix = "encoder.\(layer)."
        let query = project(input, prefix: prefix + "query")
        let key = project(input, prefix: prefix + "key")
        let value = project(input, prefix: prefix + "value")
        var attended = Array(repeating: Float.zero, count: Self.sequenceLength * Self.width)
        let scale = sqrt(Float(Self.headWidth))

        for positionIndex in 0..<Self.sequenceLength {
            for head in 0..<Self.heads {
                let headOffset = head * Self.headWidth
                var scores = Array(repeating: Float.zero, count: Self.sequenceLength)
                for keyIndex in 0..<Self.sequenceLength {
                    var dot: Float = 0
                    let queryOffset = positionIndex * Self.width + headOffset
                    let keyOffset = keyIndex * Self.width + headOffset
                    for feature in 0..<Self.headWidth {
                        dot += query[queryOffset + feature] * key[keyOffset + feature]
                    }
                    scores[keyIndex] = dot / scale
                }
                let peak = scores.max() ?? 0
                var total: Float = 0
                for index in scores.indices {
                    scores[index] = exp(scores[index] - peak)
                    total += scores[index]
                }
                let normalizer = max(total, 1e-12)
                let outputOffset = positionIndex * Self.width + headOffset
                for keyIndex in 0..<Self.sequenceLength {
                    let weight = scores[keyIndex] / normalizer
                    let valueOffset = keyIndex * Self.width + headOffset
                    for feature in 0..<Self.headWidth {
                        attended[outputOffset + feature] += weight * value[valueOffset + feature]
                    }
                }
            }
        }

        let projected = linear(
            attended,
            weight: tensors[prefix + "output.weight"]!.values,
            bias: tensors[prefix + "output.bias"]!.values,
            outputWidth: Self.width,
            sequenceLength: Self.sequenceLength
        )
        var residual = zip(input, projected).map(+)
        residual = layerNorm(
            residual,
            gamma: tensors[prefix + "norm_attention.weight"]!.values,
            beta: tensors[prefix + "norm_attention.bias"]!.values,
            sequenceLength: Self.sequenceLength
        )

        let feedForward = linear(
            residual,
            weight: tensors[prefix + "feed_forward.0.weight"]!.values,
            bias: tensors[prefix + "feed_forward.0.bias"]!.values,
            outputWidth: Self.width * 2,
            sequenceLength: Self.sequenceLength
        ).map { value in
            let cubic = value * value * value
            return 0.5 * value * (1 + tanh(0.79788456 * (value + 0.044715 * cubic)))
        }
        let feedForwardOutput = linear(
            feedForward,
            weight: tensors[prefix + "feed_forward.2.weight"]!.values,
            bias: tensors[prefix + "feed_forward.2.bias"]!.values,
            outputWidth: Self.width,
            sequenceLength: Self.sequenceLength
        )
        residual = zip(residual, feedForwardOutput).map(+)
        return layerNorm(
            residual,
            gamma: tensors[prefix + "norm_feed_forward.weight"]!.values,
            beta: tensors[prefix + "norm_feed_forward.bias"]!.values,
            sequenceLength: Self.sequenceLength
        )
    }

    private func project(_ input: [Float], prefix: String) -> [Float] {
        linear(
            input,
            weight: tensors[prefix + ".weight"]!.values,
            bias: tensors[prefix + ".bias"]!.values,
            outputWidth: Self.width,
            sequenceLength: Self.sequenceLength
        )
    }

    private func linear(
        _ input: [Float],
        weight: [Float],
        bias: [Float],
        outputWidth: Int,
        sequenceLength: Int = 1
    ) -> [Float] {
        var output = Array(repeating: Float.zero, count: outputWidth * sequenceLength)
        let inputWidth = input.count / sequenceLength
        for sequenceIndex in 0..<sequenceLength {
            let inputOffset = sequenceIndex * inputWidth
            let outputOffset = sequenceIndex * outputWidth
            for row in 0..<outputWidth {
                var value = bias[row]
                let weightOffset = row * inputWidth
                for column in 0..<inputWidth {
                    value += input[inputOffset + column] * weight[weightOffset + column]
                }
                output[outputOffset + row] = value
            }
        }
        return output
    }

    private func layerNorm(
        _ input: [Float],
        gamma: [Float],
        beta: [Float],
        sequenceLength: Int = 1
    ) -> [Float] {
        let featureCount = input.count / sequenceLength
        var output = Array(repeating: Float.zero, count: input.count)
        for sequenceIndex in 0..<sequenceLength {
            let offset = sequenceIndex * featureCount
            var mean: Float = 0
            for feature in 0..<featureCount { mean += input[offset + feature] }
            mean /= Float(featureCount)
            var variance: Float = 0
            for feature in 0..<featureCount {
                let difference = input[offset + feature] - mean
                variance += difference * difference
            }
            variance /= Float(featureCount)
            let inverse = 1 / sqrt(variance + 1e-5)
            for feature in 0..<featureCount {
                output[offset + feature] = (input[offset + feature] - mean) * inverse * gamma[feature] + beta[feature]
            }
        }
        return output
    }

    private static func tokenIDs(for tokens: [String]) -> [Int] {
        let encoded = tokens.suffix(Self.sequenceLength).map { token in
            Int(stableHash(token.lowercased()) % UInt64(Self.vocabularySize - 2)) + 2
        }
        return Array(repeating: 0, count: Self.sequenceLength - encoded.count) + encoded
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func loadWeights() -> [String: Tensor]? {
        let url = ProcessInfo.processInfo.environment["KEYDANCE_CONTEXTUAL_WEIGHTS"].map(URL.init(fileURLWithPath:))
            ?? Bundle.main.url(forResource: "ContextualAccuracyScorer", withExtension: "weights")
            ?? Bundle.module.url(forResource: "ContextualAccuracyScorer", withExtension: "weights")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        var reader = BinaryReader(data: data)
        guard reader.readBytes(count: 4) == Array("KDAC".utf8),
              reader.readUInt32() == 1,
              let tensorCount = reader.readUInt32() else { return nil }

        var tensors: [String: Tensor] = [:]
        for _ in 0..<tensorCount {
            guard let nameLength = reader.readUInt32(),
                  let nameData = reader.readBytes(count: nameLength),
                  let name = String(bytes: nameData, encoding: .utf8),
                  let rank = reader.readUInt32(),
                  let shape = reader.readUInt32Array(count: rank),
                  let valueCount = reader.readUInt32(),
                  let values = reader.readFloatArray(count: valueCount) else { return nil }
            tensors[name] = Tensor(shape: shape, values: values)
        }
        return tensors
    }

    private struct Tensor {
        let shape: [Int]
        let values: [Float]
    }

    private struct BinaryReader {
        let bytes: [UInt8]
        var offset = 0

        init(data: Data) { bytes = Array(data) }

        mutating func readBytes(count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func readUInt32() -> Int? {
            guard let bytes = readBytes(count: 4) else { return nil }
            return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        }

        mutating func readUInt32Array(count: Int) -> [Int]? {
            var values: [Int] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                guard let value = readUInt32() else { return nil }
                values.append(value)
            }
            return values
        }

        mutating func readFloatArray(count: Int) -> [Float]? {
            guard let bytes = readBytes(count: count * 4) else { return nil }
            return stride(from: 0, to: bytes.count, by: 4).map { index in
                let bits = UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24
                return Float(bitPattern: bits)
            }
        }
    }
}
