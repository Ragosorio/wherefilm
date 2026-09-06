import Foundation
import AVFoundation
import FluidAudio
import WhereFilmCore

/// Who was speaking, and when.
///
/// The transcript already says what was said and at what second. It cannot say
/// who said it, and in an archive of interviews that is most of the question:
/// the person talking is very often not the person on screen. Faces answer
/// "¿dónde sale Jorge?"; this answers "¿dónde habla Jorge?", and linking the two
/// is what makes the second question work when he is behind the camera.
///
/// ## What this costs, stated plainly
///
/// It is the one part of WhereFilm that is not universal and not entirely
/// offline, and both facts are load-bearing:
///
///  - **Apple silicon only.** FluidAudio's models are Core ML built for the
///    neural engine. On an Intel Mac this reports itself unavailable and nothing
///    else changes — the same shape as `SpeechTranscriber` falling back to
///    `DictationTranscriber`.
///  - **One download, on purpose.** The pyannote-derived weights are fetched from
///    Hugging Face the first time, which is a network request in an app whose
///    whole premise is that there are none. So it never happens implicitly:
///    `install()` is a command somebody runs, and until they do, diarization
///    reports unavailable rather than quietly reaching for the network.
///
/// Licences travel with it: FluidAudio is Apache-2.0, the pyannote weights are
/// CC-BY-4.0.
///
/// One upstream wart worth knowing about: FluidAudio writes `[Profiling]` lines
/// straight to stderr with no way to turn them off. Harmless in the app, where
/// stderr goes to Console; noisy in the CLI, where it interleaves with progress.
/// Suppressing it would mean redirecting the process's stderr around every call,
/// which would swallow real errors too — a worse trade than some noise.
public struct Diarizer: Sendable {
    public struct Options: Sendable {
        /// Segments shorter than this are dropped. A speaker label on a
        /// half-second of crosstalk is noise that will not cluster.
        public var minimumSegmentSeconds: Double = 1.0
        /// Below this the diarizer is guessing, and a guessed voice print
        /// poisons a cluster far more than a missing one costs.
        public var minimumQuality: Float = 0.5
        /// Never fetch models as a side effect of indexing.
        public var allowModelDownload = false

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
        case modelsNotInstalled
        case noAudioTrack

        public var errorDescription: String? {
            switch self {
            case .unsupportedMachine:
                "Speaker diarization needs Apple silicon; this Mac has no neural engine."
            case .modelsNotInstalled:
                "The speaker models are not installed. Run `wherefilm voices install` once."
            case .noAudioTrack:
                "The file has no audio track."
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

    /// Whether this Mac can do it at all.
    public static var isSupported: Bool { MachineProfile.current.hasNeuralEngine }

    /// Where the downloaded weights live, and whether they are there.
    public static var modelsDirectory: URL {
        OfflineDiarizerModels.defaultModelsDirectory()
    }

    public static var isInstalled: Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: modelsDirectory.path) else { return false }
        return !contents.isEmpty
    }

    public static var status: String {
        guard isSupported else {
            return "unavailable — needs Apple silicon"
        }
        return isInstalled
            ? "installed (\(modelsDirectory.path))"
            : "not installed — run `wherefilm voices install`"
    }

    /// Downloads the models. Deliberately its own verb, run by a person.
    public static func install() async throws {
        guard isSupported else { throw DiarizationError.unsupportedMachine }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
    }

    public func diarize(url: URL) async throws -> [Segment] {
        guard Self.isSupported else { throw DiarizationError.unsupportedMachine }
        guard Self.isInstalled || options.allowModelDownload else {
            throw DiarizationError.modelsNotInstalled
        }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw DiarizationError.noAudioTrack
        }

        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        // The file URL overload streams from disk in chunks. Handing it an array
        // instead would materialise the whole track — 230 MB an hour at 16 kHz,
        // which a twelve-hour recording turns into a memory problem the rest of
        // this pipeline was carefully built to avoid.
        let result = try await manager.process(url)

        return result.segments.compactMap { segment in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard end - start >= options.minimumSegmentSeconds,
                  segment.qualityScore >= options.minimumQuality,
                  !segment.embedding.isEmpty else { return nil }
            return Segment(startSeconds: start, endSeconds: end,
                           localSpeaker: segment.speakerId,
                           embedding: VectorCodec.normalized(segment.embedding),
                           quality: Double(segment.qualityScore))
        }
    }
}
