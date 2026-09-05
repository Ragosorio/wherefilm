import Foundation
import CoreGraphics
import Vision
import WhereFilmCore

/// Turns a face in a frame into a vector that can be compared with other faces.
///
/// Behind a protocol on purpose. Vision detects faces but exposes no *identity*
/// embedding — the whole request list in macOS 26 has nothing that returns a
/// faceprint — so the model has to come from outside, and the obvious candidates
/// (EdgeFace, ArcFace) are research-licensed conversions somebody has to install.
///
/// Requiring that install before any of this works would have meant building the
/// pipeline blind. Instead the pipeline is built against this protocol, shipped
/// with the descriptor the system already has, and every vector records its
/// `modelID` — so installing a real face model later is a background reindex of
/// the faces table and nothing else changes.
public protocol FaceEmbedder: Sendable {
    var modelID: String { get }
    var dimensions: Int { get }
    /// The aligned crop is 112×112, which is what face models expect.
    func embed(_ crop: CGImage) async throws -> [Float]
}

/// The descriptor macOS ships, used as a face descriptor.
///
/// **This is not a face recognition model, and pretending otherwise would be the
/// dishonest part.** `GenerateImageFeaturePrintRequest` describes pictures in
/// general: it will happily rate two photographs of the same person taken in
/// different light as less similar than two different people photographed in the
/// same room. It clusters obvious duplicates well and distinguishes strangers
/// poorly.
///
/// It is here because it makes the rest real — cropping, quality gating,
/// clustering, naming, merging, splitting, appearances and erasure are all
/// exercised and tested against it — and because it is genuinely useful for the
/// narrow case of "the same shot again". The moment a proper model is installed,
/// `modelID` changes, the old vectors stop being compared with the new ones, and
/// the same code becomes face recognition.
public struct VisionFeaturePrintEmbedder: FaceEmbedder {
    public let modelID = "vision-featureprint-v2-face"
    public let dimensions: Int

    public init(dimensions: Int = 768) {
        self.dimensions = dimensions
    }

    public func embed(_ crop: CGImage) async throws -> [Float] {
        let request = GenerateImageFeaturePrintRequest()
        let observation = try await VisionGate.shared.run {
            try await request.perform(on: crop)
        }
        let vector = Self.decode(observation)
        guard !vector.isEmpty else { throw FaceEmbeddingError.emptyDescriptor }
        return VectorCodec.normalized(vector)
    }

    static func decode(_ observation: FeaturePrintObservation) -> [Float] {
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self).prefix(observation.elementCount))
            }
        case .double:
            return observation.data.withUnsafeBytes { buffer in
                buffer.bindMemory(to: Double.self).prefix(observation.elementCount).map(Float.init)
            }
        @unknown default:
            return []
        }
    }
}

public enum FaceEmbeddingError: Error, LocalizedError {
    case emptyDescriptor
    case cropFailed

    public var errorDescription: String? {
        switch self {
        case .emptyDescriptor: "The face descriptor came back empty."
        case .cropFailed: "The face could not be cut out of the frame."
        }
    }
}

/// Cutting a face out of a frame, well enough that a descriptor means something.
public enum FaceCrop {
    /// How much context to keep around the detected box.
    ///
    /// Face models are trained on crops that include forehead, chin and a little
    /// background; a box tight to the eyes and mouth is a different distribution
    /// and scores worse against everything.
    public static let padding = 0.35
    public static let side = 112

    /// Whether this detection is worth embedding at all.
    ///
    /// Most faces in real footage are motion-blurred, turned away, or thirty
    /// pixels wide. Embedding those is not merely wasted: they land between
    /// clusters and are how one person ends up scattered across a dozen of them.
    public static func isWorthEmbedding(_ face: DetectedFace, frameWidth: Int,
                                        minimumPixels: Int = 64,
                                        minimumQuality: Double = 0.35) -> Bool {
        let pixels = face.width * Double(frameWidth)
        guard pixels >= Double(minimumPixels) else { return false }
        if let quality = face.quality, quality < minimumQuality { return false }
        // Beyond about 45° of yaw there is not enough of the face left for any
        // descriptor to be stable.
        if let yaw = face.yaw, abs(yaw) > 45 { return false }
        return true
    }

    /// Cuts out the face, padded and upright, at the size a model expects.
    ///
    /// Vision reports boxes normalised with the origin at the lower left; CGImage
    /// crops from the upper left. Getting that flip wrong produces crops of
    /// foreheads and ceilings, which is exactly the kind of bug that looks like a
    /// bad model.
    public static func cut(_ face: DetectedFace, from image: CGImage) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let padX = face.width * padding * width
        let padY = face.height * padding * height

        let rect = CGRect(
            x: face.x * width - padX,
            y: (1 - face.y - face.height) * height - padY,
            width: face.width * width + padX * 2,
            height: face.height * height + padY * 2)
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clamped.width > 8, clamped.height > 8,
              let cropped = image.cropping(to: clamped) else { return nil }
        return resize(cropped, to: side)
    }

    static func resize(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
