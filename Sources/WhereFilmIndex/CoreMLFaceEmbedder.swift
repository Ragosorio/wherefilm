import Foundation
import CoreML
import CoreGraphics
import WhereFilmCore

/// A real face recognition model, when one is installed.
///
/// Vision detects faces and exposes no identity embedding, so this is the piece
/// that has to come from outside — and the pipeline was deliberately built
/// against `FaceEmbedder` so that installing one is a background reindex rather
/// than a rewrite. This is that installation.
///
/// The model is AuraFace: a ResNet-100 trained with ArcFace's additive angular
/// margin loss, published by fal under Apache-2.0 and trained on commercially
/// usable data. That licence matters more than it looks. The obvious
/// alternatives — InsightFace's own weights, EdgeFace — are research-only, and
/// this app is already research-only because of MobileCLIP. Adding a *second*
/// non-commercial model would have made that situation permanent; adding an
/// Apache-2.0 one leaves exactly one thing to replace if this ever stops being a
/// gift.
///
/// Verified against the compiled model: input `input` is a `[1, 3, 112, 112]`
/// float32 array, output `var_2167` is `[1, 512]`.
/// `@unchecked Sendable` for the same reason `MobileCLIPImageEncoder` is: an
/// `MLModel` is not marked `Sendable` by Core ML, and prediction on a loaded
/// model is thread-safe in practice. The gate above it serialises the heavy work
/// regardless.
public final class CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    public let modelID: String
    public let dimensions = 512
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    /// Asked of the model rather than assumed: this export is half precision,
    /// and a future one might not be.
    private let inputDataType: MLMultiArrayDataType

    /// Where `Scripts/fetch-face-model.sh` puts it.
    public static func installedURL(directory: URL = AppPaths.models) -> URL? {
        let compiled = directory.appendingPathComponent("auraface.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = directory.appendingPathComponent("auraface.mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        return nil
    }

    public static var isInstalled: Bool { installedURL() != nil }

    public init(directory: URL = AppPaths.models,
                computeUnits: MLComputeUnits? = nil) throws {
        guard let url = Self.installedURL(directory: directory) else {
            throw FaceEmbeddingError.modelNotInstalled(directory)
        }
        let units = computeUnits
            ?? ComputePolicy.imageEncoding(editorRunning: false)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units

        if url.pathExtension == "mlpackage" {
            // Compile once, on this machine, for this machine — the same reason
            // the visual encoder falls back to compiling rather than trusting an
            // artifact built somewhere else.
            let compiled = try MLModel.compileModel(at: url)
            let destination = directory.appendingPathComponent("auraface.mlmodelc")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: compiled, to: destination)
            self.model = try MLModel(contentsOf: destination, configuration: configuration)
        } else {
            self.model = try MLModel(contentsOf: url, configuration: configuration)
        }

        guard let input = model.modelDescription.inputDescriptionsByName.keys.first,
              let output = model.modelDescription.outputDescriptionsByName.keys.first else {
            throw FaceEmbeddingError.unexpectedModel("no inputs or outputs")
        }
        self.inputName = input
        self.outputName = output
        self.inputDataType = model.modelDescription.inputDescriptionsByName[input]?
            .multiArrayConstraint?.dataType ?? .float32
        // The identifier is what stops these vectors from ever being compared
        // with the ones the previous descriptor produced.
        self.modelID = "auraface-r100-v1"
    }

    public func embed(_ crop: CGImage) async throws -> [Float] {
        // Everything Core ML touches happens inside the gate: Vision and Core ML
        // must not overlap in this process, which is the crash guard the whole
        // indexer is built around. Nothing but the finished vector crosses back
        // out, because none of Core ML's types are `Sendable` and none of them
        // have any business crossing an isolation boundary.
        let name = outputName
        let input = inputName
        let vector: [Float] = try await VisionGate.shared.runExclusive {
            let array = try Self.tensor(from: crop, dataType: self.inputDataType)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [input: MLFeatureValue(multiArray: array)])
            let result = try self.model.prediction(from: provider)
            guard let output = result.featureValue(for: name)?.multiArrayValue else {
                throw FaceEmbeddingError.unexpectedModel("missing output \(name)")
            }
            return Self.floats(from: output)
        }
        // ArcFace embeddings are compared by cosine, so unit length is the whole
        // contract with the clusterer.
        return VectorCodec.normalized(vector)
    }

    /// Reads a Core ML array whatever precision it happens to be in.
    ///
    /// This model is exported in half precision — both its input and its output
    /// are `Float16` — and asking Core ML for `Float` from a `Float16` array is
    /// not a conversion, it is a fatal error. Which is how this was found.
    static func floats(from array: MLMultiArray) -> [Float] {
        var values = [Float](repeating: 0, count: array.count)
        switch array.dataType {
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for index in 0..<array.count { values[index] = Float(buffer[index]) }
            }
        case .double:
            array.withUnsafeBufferPointer(ofType: Double.self) { buffer in
                for index in 0..<array.count { values[index] = Float(buffer[index]) }
            }
        default:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for index in 0..<array.count { values[index] = buffer[index] }
            }
        }
        return values
    }

    /// 112×112 RGB, channels-first, scaled to [-1, 1].
    ///
    /// ArcFace's preprocessing, written out rather than inherited: the model
    /// takes a plain multi-array, so Core ML does none of this for us, and
    /// getting the channel order or the scale wrong produces embeddings that are
    /// stable, meaningless and impossible to tell apart from a bad model.
    static func tensor(from image: CGImage,
                       dataType: MLMultiArrayDataType = .float16) throws -> MLMultiArray {
        let side = 112
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FaceEmbeddingError.cropFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Half precision, because that is what this export declares. Writing
        // Float32 into a Float16 array is a fatal error rather than a
        // conversion, so the type has to be asked for rather than assumed.
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: dataType)
        let plane = side * side
        func scaled(_ value: UInt8) -> Float { (Float(value) - 127.5) / 127.5 }

        switch dataType {
        case .float16:
            array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                for y in 0..<side {
                    for x in 0..<side {
                        let source = (y * side + x) * 4
                        let target = y * side + x
                        buffer[target] = Float16(scaled(pixels[source]))
                        buffer[plane + target] = Float16(scaled(pixels[source + 1]))
                        buffer[2 * plane + target] = Float16(scaled(pixels[source + 2]))
                    }
                }
            }
        default:
            array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for y in 0..<side {
                    for x in 0..<side {
                        let source = (y * side + x) * 4
                        let target = y * side + x
                        buffer[target] = scaled(pixels[source])
                        buffer[plane + target] = scaled(pixels[source + 1])
                        buffer[2 * plane + target] = scaled(pixels[source + 2])
                    }
                }
            }
        }
        return array
    }
}

/// Picks the best face descriptor this machine has.
///
/// The weak one is not a fallback in the usual sense — it is what makes the
/// pipeline testable and useful for near-duplicates before anybody installs
/// anything. But it is not face recognition, and when a real model is present it
/// should always win.
public enum FaceEmbedderFactory {
    public static func best() -> any FaceEmbedder {
        if CoreMLFaceEmbedder.isInstalled, let embedder = try? CoreMLFaceEmbedder() {
            return embedder
        }
        return VisionFeaturePrintEmbedder()
    }

    public static var status: String {
        CoreMLFaceEmbedder.isInstalled
            ? "AuraFace (ArcFace R100) — real face recognition"
            : "Vision feature print — not a face recognition model; "
                + "run Scripts/fetch-face-model.sh"
    }
}
