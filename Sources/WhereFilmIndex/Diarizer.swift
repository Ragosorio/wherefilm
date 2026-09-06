import Foundation
import AVFoundation
import WhereFilmCore

/// Who was speaking, and when.
///
/// The transcript already says what was said and at what second. It cannot say
/// who said it, and in an archive of interviews that is most of the question:
/// the person talking is very often not the person on screen. Faces answer
/// "¿dónde sale Jorge?"; this answers "¿dónde habla Jorge?", and linking the two
/// is what makes the second question work when he is behind the camera.
///
/// ## Why this talks to another process
///
/// Not for crash isolation, the way the Vision helper does — for architecture.
/// FluidAudio does not compile for x86_64 (`'Float16' is unavailable in macOS`,
/// inside its own text-to-speech code), and macOS 26 is the last release that
/// runs on Intel Macs. Linking it into the app would trade a working universal
/// build for a feature Intel cannot run anyway, since the models are Core ML
/// built for the neural engine.
///
/// So the dependency lives in `wherefilm-speaker-helper`, built for arm64 only.
/// On an Intel Mac the helper is simply absent and this reports itself
/// unavailable — the same shape as `SpeechTranscriber` falling back to
/// `DictationTranscriber`, and the same shape this had before the split.
///
/// ## The other cost, stated plainly
///
/// The pyannote-derived weights are fetched from Hugging Face the first time,
/// which is a network request in an app whose whole premise is that there are
/// none. So it never happens implicitly: `install()` is a command somebody runs,
/// and until they do, diarization reports unavailable rather than quietly
/// reaching for the network.
///
/// Licences travel with it: FluidAudio is Apache-2.0, the pyannote weights are
/// CC-BY-4.0.
public struct Diarizer: Sendable {
    public struct Options: Sendable {
        /// Segments shorter than this are dropped. A speaker label on a
        /// half-second of crosstalk is noise that will not cluster.
        public var minimumSegmentSeconds: Double = 1.0
        /// Below this the diarizer is guessing, and a guessed voice print
        /// poisons a cluster far more than a missing one costs.
        public var minimumQuality: Double = 0.5

        public init() {}
    }

    public struct Segment: Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        /// The label the diarizer used *within this file*. It means nothing
        /// across files; the embedding is what carries identity.
        public let localSpeaker: String
        public let embedding: [Float]
        public let quality: Double
    }

    public enum DiarizationError: Error, LocalizedError {
        case unsupportedMachine
        case helperMissing
        case noAudioTrack
        case helperFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedMachine:
                "Speaker diarization needs Apple silicon; this Mac has no neural engine."
            case .helperMissing:
                "The speaker helper is not installed in this build."
            case .noAudioTrack: "The file has no audio track."
            case .helperFailed(let detail): "Speaker analysis failed: \(detail)"
            }
        }
    }

    /// Recorded with every voice print, so a model change is a reindex rather
    /// than a silent comparison between incompatible vectors.
    public static let modelID = "fluidaudio-offline-diarizer-v1"

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Whether this Mac can do it at all: a neural engine, and a helper built
    /// for this architecture.
    public static var isSupported: Bool {
        MachineProfile.current.hasNeuralEngine && helperURL() != nil
    }

    /// Where the downloaded weights live. Owned by FluidAudio; this only needs
    /// to know whether they are there.
    public static var modelsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
    }

    public static var isInstalled: Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: modelsDirectory.path) else { return false }
        return !contents.isEmpty
    }

    public static var status: String {
        guard MachineProfile.current.hasNeuralEngine else {
            return "unavailable — needs Apple silicon"
        }
        guard helperURL() != nil else {
            return "unavailable — this build has no speaker helper"
        }
        return isInstalled
            ? "installed (\(modelsDirectory.path))"
            : "not installed — run `wherefilm voices install`"
    }

    static func helperURL() -> URL? {
        let name = "wherefilm-speaker-helper"
        var candidates: [URL] = []
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main.appendingPathComponent(name))
            candidates.append(main.appendingPathComponent("../Helpers/\(name)")
                .standardizedFileURL)
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent(name))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads the models. Deliberately its own verb, run by a person.
    public static func install() async throws {
        guard MachineProfile.current.hasNeuralEngine else {
            throw DiarizationError.unsupportedMachine
        }
        _ = try await run(request: ["operation": "install"])
    }

    public func diarize(url: URL) async throws -> [Segment] {
        guard Self.isSupported else { throw DiarizationError.unsupportedMachine }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw DiarizationError.noAudioTrack
        }
        let reply = try await Self.run(request: [
            "operation": "diarize",
            "path": url.path,
            "minimumSegmentSeconds": options.minimumSegmentSeconds,
            "minimumQuality": options.minimumQuality,
        ])
        return (reply.segments ?? []).map {
            Segment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    localSpeaker: $0.speaker,
                    embedding: VectorCodec.normalized($0.embedding),
                    quality: $0.quality)
        }
    }

    // MARK: - Talking to the helper

    struct Reply: Decodable {
        var ok: Bool
        var error: String?
        var segments: [ReplySegment]?
        var modelsDirectory: String?
    }

    struct ReplySegment: Decodable {
        var startSeconds: Double
        var endSeconds: Double
        var speaker: String
        var quality: Double
        var embedding: [Float]
    }

    /// One request, one process, then it goes away.
    ///
    /// Diarization runs once per file and takes seconds; keeping a helper
    /// resident between them would hold a Core ML model in memory for nothing.
    /// The Vision helper is pooled because it runs thousands of times a minute;
    /// this one does not.
    static func run(request: [String: Any]) async throws -> Reply {
        guard let executable = helperURL() else { throw DiarizationError.helperMissing }
        let payload = try JSONSerialization.data(withJSONObject: request)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let toHelper = Pipe(), fromHelper = Pipe()
                process.executableURL = executable
                process.standardInput = toHelper
                process.standardOutput = fromHelper
                process.standardError = FileHandle.standardError
                do {
                    try process.run()
                    var length = UInt32(payload.count).bigEndian
                    var framed = Data(bytes: &length, count: 4)
                    framed.append(payload)
                    try toHelper.fileHandleForWriting.write(contentsOf: framed)

                    let handle = fromHelper.fileHandleForReading
                    func read(_ count: Int) throws -> Data {
                        var data = Data()
                        while data.count < count {
                            guard let chunk = try handle.read(upToCount: count - data.count),
                                  !chunk.isEmpty else {
                                throw DiarizationError.helperFailed("the helper closed its output")
                            }
                            data.append(chunk)
                        }
                        return data
                    }
                    let header = try read(4)
                    let size = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    let body = try read(Int(size))
                    try? toHelper.fileHandleForWriting.close()
                    process.terminate()

                    let reply = try JSONDecoder().decode(Reply.self, from: body)
                    if !reply.ok {
                        throw DiarizationError.helperFailed(reply.error ?? "unknown")
                    }
                    continuation.resume(returning: reply)
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
