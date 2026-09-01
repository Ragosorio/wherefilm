import Foundation
import CoreML
import CoreGraphics
import WhereFilmCore

/// Which MobileCLIP variant to run.
///
/// Only v1 is available as an official Core ML export from Apple
/// (`apple/coreml-mobileclip`). MobileCLIP2 ships as PyTorch/OpenCLIP only, so it
/// needs a local `coremltools` conversion — which is why every embedding records
/// its `modelID`: upgrading is a background reindex, not a migration.
public enum MobileCLIPVariant: String, Sendable, CaseIterable {
    case s0
    case s1
    case s2
    case blt

    /// Stored with every vector. Changing the model changes this string, so old
    /// and new vectors can coexist in separate ANN indexes during a swap.
    public var modelID: String { "mobileclip-\(rawValue)-v1" }

    public var imageModelName: String { "mobileclip_\(rawValue)_image" }
    public var textModelName: String { "mobileclip_\(rawValue)_text" }

    /// Verified against the real Core ML protobuf: 256×256 RGB in, [1,512] out.
    public var inputSize: Int { 256 }
    public var dimensions: Int { 512 }

    /// Cosine similarity below which a hit from this model is noise.
    ///
    /// This lives on the *model*, not on the search engine, because the scale is
    /// a property of how the model was trained — MobileCLIP v1 puts real matches
    /// around 0.18–0.26 and unrelated pairs below 0.10, which is roughly half the
    /// spread of the original OpenAI CLIP. Swapping models has to swap these
    /// numbers too, or "how confident is this?" becomes meaningless.
    ///
    /// Measured on this hardware against real photographs: correct answers landed
    /// at 0.177–0.258, plausible-but-wrong at 0.13–0.21, and a deliberately absurd
    /// query ("a plate of spaghetti" over landscape photos) topped out at 0.099.
    public var similarityFloor: Float {
        switch self {
        case .s0, .s1, .s2, .blt: 0.12
        }
    }

    /// Similarity at which a match from this model is as good as it gets.
    public var similarityCeiling: Float {
        switch self {
        case .s0, .s1, .s2, .blt: 0.26
        }
    }

    /// Rough guidance. S0 is the background default; S2 is for people who would
    /// rather spend more time indexing for better recall.
    public var summary: String {
        switch self {
        case .s0: "smallest and fastest — the background default"
        case .s1: "middle ground"
        case .s2: "best recall of the small variants, ~2.4× the image cost of S0"
        case .blt: "largest, ViT-B/16 class"
        }
    }
}

public enum MobileCLIPError: Error, LocalizedError {
    case modelNotInstalled(String, URL)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name, let dir):
            "Core ML model '\(name)' is not installed in \(dir.path). Run Scripts/fetch-models.sh."
        case .unexpectedOutput(let detail):
            "Unexpected Core ML output: \(detail)"
        }
    }
}

/// Shared loading rules for both encoders.
enum MobileCLIPLoader {
    /// Deliberately excludes the GPU.
    ///
    /// This is the single most important knob for living next to DaVinci Resolve:
    /// the editor is very likely saturating the GPU, and the ANE is idle. It is
    /// not a guarantee of zero contention — nothing is — but it is far more
    /// sensible than fighting for the same silicon.
    static func configuration(computeUnits: MLComputeUnits) -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return config
    }

    static func load(modelName: String, directory: URL,
                     computeUnits: MLComputeUnits) throws -> MLModel {
        let compiled = directory.appendingPathComponent("\(modelName).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) {
            return try MLModel(contentsOf: compiled, configuration: configuration(computeUnits: computeUnits))
        }
        // Fall back to compiling an .mlpackage on first use, then cache the result
        // so the cost is paid once.
        let package = directory.appendingPathComponent("\(modelName).mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw MobileCLIPError.modelNotInstalled(modelName, directory)
        }
        let temporary = try MLModel.compileModel(at: package)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temporary, to: compiled)
        return try MLModel(contentsOf: compiled, configuration: configuration(computeUnits: computeUnits))
    }

    static func embedding(from provider: MLFeatureProvider) throws -> [Float] {
        guard let array = provider.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw MobileCLIPError.unexpectedOutput("missing final_emb_1")
        }
        var out = [Float](repeating: 0, count: array.count)
        array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            for i in 0..<array.count { out[i] = buffer[i] }
        }
        return VectorCodec.normalized(out)
    }
}

// MARK: - Image encoder

/// Turns keyframes into 512-d vectors.
///
/// This is the expensive half of the pipeline and the one that should be loaded
/// only while there is work, then released. Keeping the index *searchable* does
/// not require this model to be resident.
public final class MobileCLIPImageEncoder: @unchecked Sendable {
    public let variant: MobileCLIPVariant
    private let model: MLModel

    public init(variant: MobileCLIPVariant = .s0,
                directory: URL = AppPaths.models,
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        self.variant = variant
        self.model = try MobileCLIPLoader.load(
            modelName: variant.imageModelName, directory: directory, computeUnits: computeUnits)
    }

    public var modelID: String { variant.modelID }
    public var dimensions: Int { variant.dimensions }

    public func encode(_ image: CGImage) throws -> [Float] {
        let provider = try inputProvider(for: image)
        return try MobileCLIPLoader.embedding(from: model.prediction(from: provider))
    }

    /// Batched inference. Core ML pipelines a batch far better than a loop of
    /// single predictions, which matters when a single interview yields 150
    /// keyframes.
    public func encode(batch images: [CGImage]) throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        let providers = try images.map { try inputProvider(for: $0) }
        let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
        return try (0..<results.count).map { try MobileCLIPLoader.embedding(from: results.features(at: $0)) }
    }

    private func inputProvider(for image: CGImage) throws -> MLFeatureProvider {
        // Core ML does the resize and the pixel-format conversion; the scaling
        // into [0,1] is already baked into Apple's export.
        let value = try MLFeatureValue(
            cgImage: image,
            pixelsWide: variant.inputSize,
            pixelsHigh: variant.inputSize,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: nil)
        return try MLDictionaryFeatureProvider(dictionary: ["image": value])
    }
}

// MARK: - Text encoder

/// Turns a query into a 512-d vector in the same space as the keyframes.
///
/// This one is cheap and short-lived: it runs for a few milliseconds per search
/// and then can go away again.
public final class MobileCLIPTextEncoder: @unchecked Sendable {
    public let variant: MobileCLIPVariant
    private let model: MLModel
    private let tokenizer: CLIPTokenizer

    public init(variant: MobileCLIPVariant = .s0,
                directory: URL = AppPaths.models,
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        self.variant = variant
        self.tokenizer = try CLIPTokenizer(directory: directory)
        self.model = try MobileCLIPLoader.load(
            modelName: variant.textModelName, directory: directory, computeUnits: computeUnits)
    }

    public var modelID: String { variant.modelID }
    public var dimensions: Int { variant.dimensions }

    public func encode(_ text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                     dataType: .int32)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for i in tokens.indices { buffer[i] = tokens[i] }
        }
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["text": MLFeatureValue(multiArray: array)])
        return try MobileCLIPLoader.embedding(from: model.prediction(from: provider))
    }

    /// Averaging several phrasings of the same idea is a cheap, effective way to
    /// widen recall — especially useful when the query planner expands one
    /// Spanish phrase into a handful of English ones.
    public func encodeEnsemble(_ texts: [String]) throws -> [Float] {
        guard !texts.isEmpty else { return [] }
        var accumulator = [Float](repeating: 0, count: dimensions)
        for text in texts {
            let vector = try encode(text)
            for i in accumulator.indices { accumulator[i] += vector[i] }
        }
        return VectorCodec.normalized(accumulator)
    }
}
