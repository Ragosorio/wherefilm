import Testing
import Foundation
import CoreGraphics
@testable import WhereFilmCore
@testable import WhereFilmIndex

@Suite("Face descriptor")
struct FaceModelTests {
    static func swatch(red: Double, green: Double, blue: Double, side: Int = 112) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // A little structure, so the model has something to look at other than a
        // constant.
        context.setFillColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1)
        context.fillEllipse(in: CGRect(x: Double(side) * 0.25, y: Double(side) * 0.3,
                                       width: Double(side) * 0.5, height: Double(side) * 0.4))
        return context.makeImage()
    }

    @Test("The tensor is what ArcFace expects: 1×3×112×112, channels first, −1…1")
    func tensorLayout() throws {
        // Core ML does none of this for us — the model takes a plain array — and
        // getting the channel order or the scale wrong produces embeddings that
        // are stable, meaningless, and impossible to tell from a bad model.
        let image = try #require(Self.swatch(red: 1, green: 0, blue: 0))
        let tensor = try CoreMLFaceEmbedder.tensor(from: image, dataType: .float32)
        #expect(tensor.shape.map(\.intValue) == [1, 3, 112, 112])

        var red: Float = 0, green: Float = 0, blue: Float = 0
        tensor.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            let plane = 112 * 112
            // Sample a corner, which the ellipse does not cover.
            red = buffer[0]
            green = buffer[plane]
            blue = buffer[2 * plane]
        }
        #expect(abs(red - 1.0) < 0.01, "pure red maps to +1 on the first plane")
        #expect(abs(green + 1.0) < 0.01, "and to −1 on the others")
        #expect(abs(blue + 1.0) < 0.01)
    }

    @Test("When a real model is installed it produces unit vectors that discriminate")
    func modelProducesUsableEmbeddings() async throws {
        // Skipped rather than failed when nobody has run the fetch script: the
        // descriptor is optional by design, and a red test on a machine that
        // simply has not installed it would be noise.
        try #require(CoreMLFaceEmbedder.isInstalled,
                     "no face model installed — Scripts/fetch-face-model.sh")
        let embedder = try CoreMLFaceEmbedder()
        #expect(embedder.modelID == "auraface-r100-v1")

        let first = try #require(Self.swatch(red: 0.9, green: 0.7, blue: 0.6))
        let second = try #require(Self.swatch(red: 0.2, green: 0.3, blue: 0.8))

        let a = try await embedder.embed(first)
        let b = try await embedder.embed(second)
        let again = try await embedder.embed(first)

        #expect(a.count == 512)
        let length = sqrt(a.reduce(0) { $0 + Double($1 * $1) })
        #expect(abs(length - 1) < 0.001, "cosine clustering depends on unit length")

        // Deterministic for the same pixels…
        #expect(VectorCodec.dot(a, again) > 0.999)
        // …and not merely returning the same thing for everything, which is what
        // a mis-shaped tensor looks like.
        #expect(VectorCodec.dot(a, b) < 0.999)
    }

    @Test("The factory prefers a real model and says which one it picked")
    func factoryPrefersTheRealModel() {
        let status = FaceEmbedderFactory.status
        if CoreMLFaceEmbedder.isInstalled {
            #expect(status.contains("AuraFace"))
            #expect(FaceEmbedderFactory.best().modelID == "auraface-r100-v1")
        } else {
            // The weak descriptor must never be mistaken for face recognition.
            #expect(status.contains("not a face recognition model"))
            #expect(FaceEmbedderFactory.best().modelID.contains("featureprint"))
        }
    }
}

@Suite("Half precision")
struct HalfPrecisionTests {
    /// `Float16` is unavailable on x86_64 macOS, so this app converts by hand —
    /// which means the conversion has to be right rather than assumed.
    @Test("Round-tripping a float through half precision keeps its value")
    func roundTrip() {
        for value in [0.0, 1.0, -1.0, 0.5, -0.5, 0.125, 127.5 / 127.5,
                      -0.007874, 0.99951, -1024.0, 2048.0] as [Float] {
            let back = Half.float(from: Half.bits(from: value))
            let tolerance = max(0.001, abs(value) * 0.001)
            #expect(abs(back - value) <= tolerance,
                    "\(value) came back as \(back)")
        }
    }

    @Test("The pixel range the model is fed survives the conversion")
    func pixelRangeSurvives() {
        // Every value the tensor can hold is (byte − 127.5) / 127.5, so the
        // whole domain is −1…1 and it is small enough to check exhaustively.
        for byte in 0...255 {
            let value = (Float(byte) - 127.5) / 127.5
            let back = Half.float(from: Half.bits(from: value))
            #expect(abs(back - value) < 0.002, "byte \(byte): \(value) → \(back)")
        }
    }

    @Test("Zero, infinity and sign are not mangled")
    func edges() {
        #expect(Half.float(from: Half.bits(from: 0)) == 0)
        #expect(Half.float(from: Half.bits(from: -0.0)).sign == .minus)
        #expect(Half.float(from: Half.bits(from: 100_000)).isInfinite)
        #expect(Half.float(from: Half.bits(from: -100_000)) == -.infinity)
    }
}
