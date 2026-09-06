import Foundation
import FluidAudio

// Speaker diarization, in a process of its own.
//
// Not for isolation this time — for architecture. FluidAudio does not compile
// for x86_64 (`'Float16' is unavailable in macOS` inside its own TTS code), and
// macOS 26 is the last release that runs on Intel Macs. Linking it into the app
// would trade a working universal build for a feature Intel cannot run anyway.
//
// So it lives here, this helper is built for arm64 only, and on an Intel Mac it
// is simply absent — which is exactly what `Diarizer.isSupported` already
// reported before any of this existed. The app keeps one binary for both
// families and loses nothing it could have had.
//
// The protocol is the same dull one the Vision helper uses: a length-prefixed
// JSON request in, a length-prefixed JSON reply out, one at a time.

struct Request: Decodable {
    /// "diarize" or "install".
    var operation: String
    var path: String?
    var minimumSegmentSeconds: Double?
    var minimumQuality: Double?
}

struct Segment: Encodable {
    var startSeconds: Double
    var endSeconds: Double
    var speaker: String
    var quality: Double
    var embedding: [Float]
}

struct Response: Encodable {
    var ok: Bool
    var error: String?
    var segments: [Segment]?
    var modelsDirectory: String?
}

func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
        guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty
        else { return nil }
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

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let decoder = JSONDecoder()
let encoder = JSONEncoder()

while let payload = readFrame(from: input) {
    var response = Response(ok: false)
    do {
        let request = try decoder.decode(Request.self, from: payload)
        switch request.operation {
        case "install":
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels()
            response = Response(ok: true,
                                modelsDirectory: OfflineDiarizerModels
                                    .defaultModelsDirectory().path)
        case "diarize":
            guard let path = request.path else {
                throw NSError(domain: "wherefilm.speakers", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "no path given",
                ])
            }
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels()
            let result = try await manager.process(URL(fileURLWithPath: path))
            let minimumSeconds = request.minimumSegmentSeconds ?? 1
            let minimumQuality = Float(request.minimumQuality ?? 0.5)
            let segments = result.segments.compactMap { segment -> Segment? in
                let start = Double(segment.startTimeSeconds)
                let end = Double(segment.endTimeSeconds)
                guard end - start >= minimumSeconds,
                      segment.qualityScore >= minimumQuality,
                      !segment.embedding.isEmpty else { return nil }
                return Segment(startSeconds: start, endSeconds: end,
                               speaker: segment.speakerId,
                               quality: Double(segment.qualityScore),
                               embedding: segment.embedding)
            }
            response = Response(ok: true, segments: segments)
        default:
            throw NSError(domain: "wherefilm.speakers", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "unknown operation '\(request.operation)'",
            ])
        }
    } catch {
        response = Response(ok: false, error: error.localizedDescription)
    }
    guard let encoded = try? encoder.encode(response) else { break }
    writeFrame(encoded, to: output)
}
