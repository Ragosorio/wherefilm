import Foundation
import CoreGraphics
import Vision
import WhereFilmCore

/// Everything worth knowing about one keyframe, gathered in one pass.
///
/// The keyframe is already decoded, already sized for reading, and already paid
/// for. Every extra question asked of it is close to free in I/O and costs only
/// compute — which is exactly why the ceiling on how many questions can be asked
/// was never about the questions. It was `RecognizeTextRequest` crashing above
/// depth three, which capped *all* Vision work in this process at two requests.
///
/// With helpers, the arithmetic changes: three or four processes at depth one
/// each, and each round trip can carry three analyses instead of one, because
/// the expensive part was moving the frame there.
public struct FrameAnalysis: Sendable {
    public var text: RecognizedTextResult?
    public var labels: [SceneLabel]
    public var faces: [DetectedFace]

    public init(text: RecognizedTextResult? = nil, labels: [SceneLabel] = [],
                faces: [DetectedFace] = []) {
        self.text = text
        self.labels = labels
        self.faces = faces
    }

    public var isEmpty: Bool { text == nil && labels.isEmpty && faces.isEmpty }
}

public struct SceneLabel: Sendable, Hashable {
    public let identifier: String
    public let confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

public struct DetectedFace: Sendable {
    /// Normalised to the frame, origin lower-left, as Vision reports it.
    public let x: Double, y: Double, width: Double, height: Double
    public let quality: Double?
    public let roll: Double?, yaw: Double?, pitch: Double?
    /// Eye centres, normalised, origin **upper-left** — the coordinate space a
    /// crop is drawn in. The box and the eyes genuinely use different origins
    /// here, which is worth stating rather than discovering.
    public let leftEye: CGPoint?
    public let rightEye: CGPoint?

    public init(x: Double, y: Double, width: Double, height: Double,
                quality: Double? = nil, roll: Double? = nil,
                yaw: Double? = nil, pitch: Double? = nil,
                leftEye: CGPoint? = nil, rightEye: CGPoint? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.quality = quality
        self.roll = roll; self.yaw = yaw; self.pitch = pitch
        self.leftEye = leftEye
        self.rightEye = rightEye
    }
}

/// Runs the per-frame analyses, out of process when it can and in-process when
/// it must.
public struct FrameAnalyzer: Sendable {
    public struct Options: Sendable {
        public var recognizesText = true
        /// Scene and object labels from Vision's own classifier.
        ///
        /// This is the cheapest recall in the product and it was simply missing.
        /// MobileCLIP-S0 is the smallest model in its family and is weakest at
        /// exactly what people search for by name — "pato", "micrófono", "perro"
        /// — while `ClassifyImageRequest` answers that from a taxonomy, on a
        /// frame that has already been decoded, and returns *text*, which means
        /// the translator makes it work in Spanish without touching the visual
        /// model at all.
        public var classifiesScene = true
        public var detectsFaces = false
        /// Telling Vision which languages to expect. Left nil, it detects per
        /// frame, which is both slower and worse on the short bursts of text a
        /// slate or a badge actually contains.
        public var recognitionLanguages: [String]?
        /// Names, brands and slate vocabulary the recogniser should prefer over
        /// its own language model's guesses.
        public var customWords: [String] = []
        public var minimumTextConfidence: Float = 0.35
        public var minimumLabelConfidence: Float = 0.3
        public var maximumLabels = 5
        /// Run the cheap screening pass before the accurate one. Off, measured:
        /// it erased text the accurate pass found on a scanned quotation.
        public var screensFirst = false

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    private var request: VisionHelperPool.Request {
        var operations: [String] = []
        if options.recognizesText { operations.append("text") }
        if options.classifiesScene { operations.append("labels") }
        if options.detectsFaces { operations.append("faces") }
        return VisionHelperPool.Request(
            operations: operations,
            recognitionLanguages: options.recognitionLanguages,
            customWords: options.customWords.isEmpty ? nil : options.customWords,
            minimumConfidence: options.minimumTextConfidence,
            maximumLabels: options.maximumLabels)
    }

    /// Analyses a batch of frames, preserving order.
    public func analyze(batch images: [CGImage]) async -> [FrameAnalysis] {
        guard !images.isEmpty else { return [] }
        guard !request.operations.isEmpty else {
            return Array(repeating: FrameAnalysis(), count: images.count)
        }

        if await VisionHelperPool.shared.isUsable() {
            let width = await VisionHelperPool.shared.capacity()
            if let results = await analyzeWithHelpers(images, width: max(1, width)) {
                return results
            }
        }
        return await analyzeInProcess(images)
    }

    // MARK: - Out of process

    private func analyzeWithHelpers(_ images: [CGImage], width: Int) async -> [FrameAnalysis]? {
        var results = [FrameAnalysis?](repeating: nil, count: images.count)
        var failures = 0

        await withTaskGroup(of: (Int, FrameAnalysis?).self) { group in
            var next = 0
            func submit(_ index: Int) {
                let spec = request
                let image = images[index]
                group.addTask {
                    guard let data = VisionHelperPool.encode(image) else { return (index, nil) }
                    guard let response = try? await VisionHelperPool.shared.analyze(
                        imageData: data, request: spec), response.ok else { return (index, nil) }
                    return (index, Self.convert(response))
                }
            }
            while next < min(width, images.count) { submit(next); next += 1 }
            for await (index, analysis) in group {
                results[index] = analysis
                if analysis == nil { failures += 1 }
                if next < images.count { submit(next); next += 1 }
            }
        }

        // A single failed frame is a frame; a batch that mostly failed means the
        // helpers are gone, and the caller deserves the in-process path rather
        // than a silently emptier index.
        guard failures * 2 <= images.count else { return nil }
        return results.map { $0 ?? FrameAnalysis() }
    }

    private static func convert(_ response: VisionHelperPool.Response) -> FrameAnalysis {
        FrameAnalysis(
            text: response.text.map {
                RecognizedTextResult(text: $0.text, confidence: $0.confidence)
            },
            labels: (response.labels ?? []).map {
                SceneLabel(identifier: $0.identifier, confidence: $0.confidence)
            },
            faces: (response.faces ?? []).map { face in
                DetectedFace(
                    x: face.x, y: face.y, width: face.width, height: face.height,
                    quality: face.quality, roll: face.roll, yaw: face.yaw, pitch: face.pitch,
                    leftEye: face.leftEyeX.flatMap { x in
                        face.leftEyeY.map { CGPoint(x: x, y: $0) } },
                    rightEye: face.rightEyeX.flatMap { x in
                        face.rightEyeY.map { CGPoint(x: x, y: $0) } })
            })
    }

    // MARK: - In process

    /// The original path, unchanged in behaviour and still bounded by
    /// `VisionGate`. It is the answer whenever the helper cannot be found — a
    /// bundle built before this existed, a test binary, a copy someone moved out
    /// of its folder — and it must stay correct, not merely present.
    /// Test seam: the in-process path, reachable without arranging for the
    /// helper to be missing.
    func analyzeInProcessForTesting(_ images: [CGImage]) async -> [FrameAnalysis] {
        await analyzeInProcess(images)
    }

    private func analyzeInProcess(_ images: [CGImage]) async -> [FrameAnalysis] {
        var textResults = [RecognizedTextResult?](repeating: nil, count: images.count)
        if options.recognizesText {
            var textOptions = TextRecognizer.Options()
            textOptions.screensFirst = options.screensFirst
            textOptions.minimumConfidence = options.minimumTextConfidence
            textOptions.recognitionLanguages = options.recognitionLanguages
            textOptions.customWords = options.customWords
            textResults = await TextRecognizer(options: textOptions).recognize(batch: images)
        }

        var labelResults = [[SceneLabel]](repeating: [], count: images.count)
        if options.classifiesScene {
            for (index, image) in images.enumerated() {
                labelResults[index] = await Self.classifyInProcess(
                    image, floor: options.minimumLabelConfidence,
                    limit: options.maximumLabels)
            }
        }

        var faceResults = [[DetectedFace]](repeating: [], count: images.count)
        if options.detectsFaces {
            for (index, image) in images.enumerated() {
                faceResults[index] = await Self.detectFacesInProcess(image)
            }
        }

        return images.indices.map { index in
            FrameAnalysis(text: textResults[index], labels: labelResults[index],
                          faces: faceResults[index])
        }
    }

    static func classifyInProcess(_ image: CGImage, floor: Float, limit: Int) async -> [SceneLabel] {
        let request = ClassifyImageRequest()
        guard let observations = try? await VisionGate.shared.run({
            try await request.perform(on: image)
        }) else { return [] }
        return observations
            .filter { $0.confidence >= floor }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
    }

    static func detectFacesInProcess(_ image: CGImage) async -> [DetectedFace] {
        guard let observations = try? await VisionGate.shared.run({
            try await DetectFaceLandmarksRequest().perform(on: image)
        }) else { return [] }
        let size = CGSize(width: image.width, height: image.height)
        func centre(_ points: [CGPoint]) -> CGPoint? {
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count) / size.width,
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count) / size.height)
        }
        var qualities: [UUID: Double] = [:]
        if let scored = try? await VisionGate.shared.run({
            try await DetectFaceCaptureQualityRequest().perform(on: image)
        }) {
            for observation in scored {
                guard let score = observation.captureQuality?.score else { continue }
                qualities[observation.uuid] = Double(score)
            }
        }
        return observations.map { observation in
            let box: CGRect = observation.boundingBox.cgRect
            return DetectedFace(
                x: Double(box.origin.x), y: Double(box.origin.y),
                width: Double(box.size.width), height: Double(box.size.height),
                quality: qualities[observation.uuid],
                roll: observation.roll.converted(to: .degrees).value,
                yaw: observation.yaw.converted(to: .degrees).value,
                pitch: observation.pitch.converted(to: .degrees).value,
                leftEye: observation.landmarks.flatMap {
                    centre($0.leftEye.pointsInImageCoordinates(size, origin: .upperLeft)) },
                rightEye: observation.landmarks.flatMap {
                    centre($0.rightEye.pointsInImageCoordinates(size, origin: .upperLeft)) })
        }
    }
}
