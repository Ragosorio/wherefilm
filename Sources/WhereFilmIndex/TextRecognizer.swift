import Foundation
import CoreGraphics
import Vision

public struct RecognizedTextResult: Sendable {
    public let text: String
    public let confidence: Double
}

/// On-screen text recognition over the keyframes we already picked.
///
/// This is the cheapest recall the product gets. CLIP is not reliable at reading
/// the number on a slate, the name on a badge or the word on a shop sign, but
/// Vision is — and it runs on frames we already decoded, so the marginal cost is
/// close to nothing:
///
///     "the interview in front of the McDonald's sign"
///     "the frame where 4582 appears"
///     "the shot with a badge that said ACME"
public struct TextRecognizer: Sendable {
    public struct Options: Sendable {
        public var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
        public var usesLanguageCorrection = true
        public var automaticallyDetectsLanguage = true
        /// Drop noise: single stray glyphs from compression artefacts are not
        /// worth indexing.
        public var minimumConfidence: Float = 0.35
        public var minimumLength = 2

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func recognize(_ image: CGImage) async throws -> RecognizedTextResult? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.automaticallyDetectsLanguage = options.automaticallyDetectsLanguage

        let observations = try await request.perform(on: image)
        var lines: [String] = []
        var confidences: [Float] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= options.minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= options.minimumLength else { continue }
            lines.append(text)
            confidences.append(candidate.confidence)
        }

        guard !lines.isEmpty else { return nil }
        let average = confidences.reduce(0, +) / Float(confidences.count)
        return RecognizedTextResult(text: lines.joined(separator: " "), confidence: Double(average))
    }
}
