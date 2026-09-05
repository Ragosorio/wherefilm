import Foundation
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers

// A tiny, disposable process that does one thing: run Vision on an image handed
// to it over a pipe, and answer.
//
// It exists because of a fault that is not ours. `RecognizeTextRequest` corrupts
// memory inside Apple's TextRecognition framework past roughly three concurrent
// requests, and again when Core ML image work overlaps it — measured, repeatedly,
// on macOS 26.5.2. The in-process answer was a gate that allows two requests and
// nothing else alongside them, which is correct and costs most of the machine:
// Vision itself scales 4.6× to depth 8, and OCR is about 90% of the visual pass.
//
// One process per concurrent request buys back that scaling *and* turns the
// crash into a contained event. When Apple's framework dies here, a 30 MB helper
// dies with it and the job is retried. Today it takes the whole application down,
// on the one machine nobody can attach a debugger to.
//
// The protocol is deliberately the dullest thing that works: length-prefixed
// frames in, length-prefixed JSON out, one request at a time. No XPC, no
// entitlements, no service registration — and because the helper holds no state,
// killing it is always safe.

struct Request: Decodable {
    /// What to run. Unknown operations answer with an error rather than exiting:
    /// a newer app talking to an older helper should degrade, not die.
    var operations: [String]
    var recognitionLanguages: [String]?
    var customWords: [String]?
    var minimumConfidence: Float?
    var maximumLabels: Int?
}

struct RecognizedText: Encodable {
    var text: String
    var confidence: Double
}

struct Label: Encodable {
    var identifier: String
    var confidence: Double
}

struct Face: Encodable {
    var x: Double, y: Double, width: Double, height: Double
    var quality: Double?
    var roll: Double?, yaw: Double?, pitch: Double?
}

struct Response: Encodable {
    var ok: Bool
    var error: String?
    var text: RecognizedText?
    var labels: [Label]?
    var faces: [Face]?
}

// MARK: - Framing

/// Reads exactly `count` bytes or returns nil at end of input. A short read on a
/// pipe is normal, not an error, so this loops rather than trusting one call.
func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
        guard let chunk = try? handle.read(upToCount: count - data.count),
              !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

func readFrame(from handle: FileHandle) -> Data? {
    guard let header = readExactly(4, from: handle) else { return nil }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    guard length > 0, length < 64 * 1024 * 1024 else { return nil }
    return readExactly(Int(length), from: handle)
}

func writeFrame(_ payload: Data, to handle: FileHandle) {
    var length = UInt32(payload.count).bigEndian
    var out = Data(bytes: &length, count: 4)
    out.append(payload)
    try? handle.write(contentsOf: out)
}

// MARK: - Work

func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func recognizeText(_ image: CGImage, request spec: Request) async throws -> RecognizedText? {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let languages = spec.recognitionLanguages, !languages.isEmpty {
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.automaticallyDetectsLanguage = false
    } else {
        request.automaticallyDetectsLanguage = true
    }
    if let words = spec.customWords, !words.isEmpty {
        request.customWords = words
    }

    let observations = try await request.perform(on: image)
    let floor = spec.minimumConfidence ?? 0.35
    var lines: [String] = []
    var total = 0.0
    var counted = 0
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first,
              candidate.confidence >= floor else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { continue }
        lines.append(text)
        total += Double(candidate.confidence)
        counted += 1
    }
    guard !lines.isEmpty else { return nil }
    return RecognizedText(text: lines.joined(separator: "\n"),
                          confidence: counted == 0 ? 0 : total / Double(counted))
}

func classify(_ image: CGImage, request spec: Request) async throws -> [Label] {
    let request = ClassifyImageRequest()
    let observations = try await request.perform(on: image)
    let floor = spec.minimumConfidence ?? 0.3
    return observations
        .filter { $0.confidence >= floor }
        .sorted { $0.confidence > $1.confidence }
        .prefix(spec.maximumLabels ?? 5)
        .map { Label(identifier: $0.identifier, confidence: Double($0.confidence)) }
}

func detectFaces(_ image: CGImage) async throws -> [Face] {
    let rectangles = try await DetectFaceRectanglesRequest().perform(on: image)
    guard !rectangles.isEmpty else { return [] }

    // Capture quality is what makes face work affordable: most frames of a face
    // are motion-blurred, tiny or turned away, and embedding those is how a
    // person ends up scattered across a dozen clusters.
    var qualities: [UUID: Double] = [:]
    if let observations = try? await DetectFaceCaptureQualityRequest().perform(on: image) {
        for observation in observations {
            guard let score = observation.captureQuality?.score else { continue }
            qualities[observation.uuid] = Double(score)
        }
    }

    var faces: [Face] = []
    for observation in rectangles {
        let box: CGRect = observation.boundingBox.cgRect
        let x = Double(box.origin.x)
        let y = Double(box.origin.y)
        let width = Double(box.size.width)
        let height = Double(box.size.height)
        let roll = observation.roll.converted(to: .degrees).value
        let yaw = observation.yaw.converted(to: .degrees).value
        let pitch = observation.pitch.converted(to: .degrees).value
        faces.append(Face(x: x, y: y, width: width, height: height,
                          quality: qualities[observation.uuid],
                          roll: roll, yaw: yaw, pitch: pitch))
    }
    return faces
}

// MARK: - Loop

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let decoder = JSONDecoder()
let encoder = JSONEncoder()

while true {
    // Two frames per request: the JSON spec, then the image bytes. Splitting them
    // keeps the image out of base64, which would cost a third more bytes for
    // nothing.
    guard let specData = readFrame(from: input),
          let imageData = readFrame(from: input) else { break }

    var response = Response(ok: false)
    do {
        let spec = try decoder.decode(Request.self, from: specData)
        guard let image = decode(imageData) else {
            throw NSError(domain: "wherefilm.vision", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not decode the image",
            ])
        }
        for operation in spec.operations {
            switch operation {
            case "text": response.text = try await recognizeText(image, request: spec)
            case "labels": response.labels = try await classify(image, request: spec)
            case "faces": response.faces = try await detectFaces(image)
            default:
                throw NSError(domain: "wherefilm.vision", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unknown operation '\(operation)'",
                ])
            }
        }
        response.ok = true
    } catch {
        response = Response(ok: false, error: error.localizedDescription)
    }

    guard let payload = try? encoder.encode(response) else { break }
    writeFrame(payload, to: output)
}
