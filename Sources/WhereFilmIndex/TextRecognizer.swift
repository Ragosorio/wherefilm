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
///
/// ## Why an optional two-pass mode exists
///
/// Measured on this machine over 24 real photographs, one Vision configuration
/// per process so the framework's model cache cannot charge one variant for
/// another's warm-up:
///
///     .fast                   ~6 ms per image
///     .accurate            ~100–650 ms per image
///
/// Most frames in real footage contain no text at all, so the cheap pass can be
/// useful for throughput experiments. It is not enabled by default: a measured
/// false negative on a scanned quotation showed that screening can erase the
/// exact text someone expects WhereFilm to find. The accurate pass remains the
/// product default; `screensFirst` makes the speed/recall trade-off explicit.
public struct TextRecognizer: Sendable {
    public struct Options: Sendable {
        /// Run the cheap `.fast` pass first and only pay for `.accurate` where
        /// it saw something.
        ///
        /// Off by default, because screening is not free in *recall*: measured
        /// over ten real images the fast recogniser returned nothing at all on
        /// a scanned quotation where the accurate one found five lines. A
        /// document like that is precisely what someone searches for, so a
        /// photo — one frame, ~100 ms — is always read properly.
        ///
        /// Video is where this option may eventually earn its keep: a long clip
        /// yields hundreds of keyframes and accurate OCR is expensive. It stays
        /// off until a larger recall benchmark proves that missed text is an
        /// acceptable trade, rather than assuming neighbouring frames cover it.
        public var screensFirst = false
        public var usesLanguageCorrection = true
        public var automaticallyDetectsLanguage = true
        /// Drop noise: single stray glyphs from compression artefacts are not
        /// worth indexing.
        public var minimumConfidence: Float = 0.35
        /// The screening pass is deliberately far more forgiving than the final
        /// one. It only decides *whether* to look closer: a false positive costs
        /// one accurate pass, a false negative loses the text for good. Any
        /// candidate at all is reason enough to look properly.
        public var screeningConfidence: Float = 0
        public var minimumLength = 2

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func recognize(_ image: CGImage) async throws -> RecognizedTextResult? {
        if options.screensFirst, try await !mightContainText(image) { return nil }
        return try await read(image, level: .accurate,
                              languageCorrection: options.usesLanguageCorrection,
                              minimumConfidence: options.minimumConfidence)
    }

    /// The cheap pass. Answers only "is it worth looking properly?".
    public func mightContainText(_ image: CGImage) async throws -> Bool {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        // Both are pure cost for a yes/no question.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false

        let prepared = request
        let observations = try await VisionGate.shared.run {
            try await prepared.perform(on: image)
        }
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= options.screeningConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= options.minimumLength { return true }
        }
        return false
    }

    private func read(_ image: CGImage,
                      level: RecognizeTextRequest.RecognitionLevel,
                      languageCorrection: Bool,
                      minimumConfidence: Float) async throws -> RecognizedTextResult? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = options.automaticallyDetectsLanguage

        let prepared = request
        let observations = try await VisionGate.shared.run {
            try await prepared.perform(on: image)
        }
        var lines: [String] = []
        var confidences: [Float] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= options.minimumLength else { continue }
            lines.append(text)
            confidences.append(candidate.confidence)
        }

        guard !lines.isEmpty else { return nil }
        let average = confidences.reduce(0, +) / Float(confidences.count)
        return RecognizedTextResult(text: lines.joined(separator: " "), confidence: Double(average))
    }

    /// Reads a batch of frames concurrently, preserving input order.
    ///
    /// Vision releases the thread while the recogniser works, so running frames
    /// one at a time left the machine measurably idle. `width` only controls how
    /// many frames are queued up here; the real ceiling on concurrent Vision
    /// work is `VisionGate`, which is what stops the recogniser from parking
    /// every cooperative thread and crashing TextRecognition.
    ///
    /// The default follows the gate rather than a fixed 4. A hardcoded 4 meant
    /// that indexing a *single* large file — the common case for a long
    /// interview — could never reach the gate's capacity no matter how idle the
    /// machine was, so half the measured Vision throughput was unreachable
    /// whenever the queue held one heavy job instead of several light ones.
    public func recognize(batch images: [CGImage], width: Int = 4)
        async -> [RecognizedTextResult?]
    {
        guard !images.isEmpty else { return [] }
        let limit = max(1, min(width, images.count))
        var results = [RecognizedTextResult?](repeating: nil, count: images.count)

        await withTaskGroup(of: (Int, RecognizedTextResult?).self) { group in
            var next = 0
            func submit(_ index: Int) {
                let image = images[index]
                group.addTask { (index, try? await self.recognize(image)) }
            }
            while next < limit { submit(next); next += 1 }
            for await (index, result) in group {
                results[index] = result
                if next < images.count { submit(next); next += 1 }
            }
        }
        return results
    }
}
