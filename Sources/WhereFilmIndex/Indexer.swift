import Foundation
import CoreGraphics
import WhereFilmCore
import WhereFilmML

public enum IndexerEvent: Sendable {
    case started(assetID: Int64, task: JobTask, name: String)
    case finished(assetID: Int64, task: JobTask, detail: String)
    case failed(assetID: Int64, task: JobTask, error: String)
    case skipped(assetID: Int64, task: JobTask, reason: String)
    case throttled(ThrottleReason)
    case idle
    case modelLoaded(String)
    case modelReleased(String)
}

/// The background worker: takes one job at a time and turns files into
/// searchable intelligence.
///
/// The shape matters as much as the work. Instead of an app that keeps every
/// model resident around the clock, a small coordinator holds the database and
/// disposable workers load a model, process a batch, save, and let the memory go.
/// Keeping the index *searchable* costs almost nothing; only the act of indexing
/// is expensive, and only while it's happening.
public actor Indexer {
    public struct Options: Sendable {
        public var variant: MobileCLIPVariant = .s0
        public var sampler = KeyframeSampler.Options()
        public var recognizeText = true
        public var storeMomentPreviews = true
        public var transcriptionLocale: Locale = Locale.current
        /// Release the image encoder after this long without visual work, so the
        /// RAM goes back to the system between bursts.
        public var modelIdleTimeout: TimeInterval = 45
        /// How long to wait before looking at the queue again when it's empty.
        public var idlePollSeconds: TimeInterval = 5

        public init() {}
    }

    let store: IndexStore
    let previews: PreviewCache
    let volumes: VolumeRegistry
    let vectorIndex: VectorIndex
    public var options: Options
    public var governor: ResourceGovernor

    private var imageEncoder: MobileCLIPImageEncoder?
    private var lastVisualWork = Date.distantPast
    private var onEvent: (@Sendable (IndexerEvent) -> Void)?

    public init(store: IndexStore,
                vectorIndex: VectorIndex,
                previews: PreviewCache? = nil,
                volumes: VolumeRegistry = VolumeRegistry(),
                options: Options = Options(),
                governor: ResourceGovernor = ResourceGovernor()) {
        self.store = store
        self.vectorIndex = vectorIndex
        self.previews = previews ?? PreviewCache(store: store)
        self.volumes = volumes
        self.options = options
        self.governor = governor
    }

    public func setEventHandler(_ handler: @escaping @Sendable (IndexerEvent) -> Void) {
        onEvent = handler
    }

    public func setGovernorSettings(_ settings: ResourceGovernor.Settings) {
        governor.settings = settings
    }

    // MARK: - Loop

    /// Runs until cancelled. Honours the governor between every single job, so
    /// pressing Pause takes effect at the next job boundary rather than at the
    /// end of a three-hour transcription queue.
    public func run() async {
        try? store.requeueStaleJobs()
        try? await vectorIndex.openForWriting()

        while !Task.isCancelled {
            let decision = governor.decide()
            guard decision.isWorking else {
                emit(.throttled(decision.reason))
                await releaseModelsIfIdle(force: true)
                try? await Task.sleep(for: .seconds(options.idlePollSeconds))
                continue
            }

            let didWork = await runOnce(allowedTasks: decision.allowedTasks)
            if !didWork {
                emit(.idle)
                await releaseModelsIfIdle(force: true)
                try? await vectorIndex.save()
                try? await Task.sleep(for: .seconds(options.idlePollSeconds))
            } else {
                await releaseModelsIfIdle(force: false)
            }
        }

        try? await vectorIndex.save()
    }

    /// Processes at most one job. Returns false when the queue had nothing to do.
    @discardableResult
    public func runOnce(allowedTasks: [JobTask]) async -> Bool {
        guard let job = (try? store.claimNextJob(tasks: allowedTasks)) ?? nil else { return false }
        guard let asset = try? store.asset(id: job.assetID) else {
            try? store.fail(job: job, error: "asset vanished")
            return true
        }

        emit(.started(assetID: job.assetID, task: job.task, name: asset.displayName))
        do {
            let detail = try await process(job: job, asset: asset)
            try store.complete(job: job)
            emit(.finished(assetID: job.assetID, task: job.task, detail: detail))
        } catch let error as IndexerSkip {
            try? store.complete(job: job)
            emit(.skipped(assetID: job.assetID, task: job.task, reason: error.reason))
        } catch {
            try? store.fail(job: job, error: error.localizedDescription)
            emit(.failed(assetID: job.assetID, task: job.task, error: error.localizedDescription))
        }
        return true
    }

    /// Drains the queue and returns. Used by the CLI and by tests, where an
    /// endless loop would be unhelpful.
    @discardableResult
    public func drain(allowedTasks: [JobTask] = JobTask.allCases, limit: Int = .max) async -> Int {
        try? store.requeueStaleJobs()
        try? await vectorIndex.openForWriting()
        var processed = 0
        while processed < limit, await runOnce(allowedTasks: allowedTasks) {
            processed += 1
        }
        try? await vectorIndex.save()
        await releaseModelsIfIdle(force: true)
        return processed
    }

    // MARK: - Job dispatch

    private func process(job: Job, asset: Asset) async throws -> String {
        switch job.task {
        case .metadata: try await processMetadata(asset: asset)
        case .visual: try await processVisual(asset: asset)
        case .ocr: try await processOCRBackfill(asset: asset)
        case .transcribe: try await processTranscription(asset: asset)
        case .strongHash: try processStrongHash(asset: asset)
        }
    }

    /// Resolves an asset to a readable file, or explains why it can't be reached.
    /// An offline drive is not an error — it's a "come back later".
    private func onlineURL(for assetID: Int64) throws -> URL {
        let locations = try store.locations(assetID: assetID)
        for location in locations {
            guard let url = volumes.absoluteURL(volumeUUID: location.volumeUUID,
                                                relativePath: location.relativePath),
                  FileManager.default.isReadableFile(atPath: url.path) else { continue }
            return url
        }
        throw IndexerSkip(reason: locations.isEmpty
            ? "no known location"
            : "all known locations are offline")
    }

    // MARK: - Level A

    private func processMetadata(asset: Asset) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        let info = try await MediaProbe().probe(url: url)

        var updated = asset
        updated.durationSeconds = info.durationSeconds ?? asset.durationSeconds
        updated.width = info.width ?? asset.width
        updated.height = info.height ?? asset.height
        updated.createdAt = info.createdAt ?? asset.createdAt
        updated.cameraMake = info.cameraMake ?? asset.cameraMake
        updated.cameraModel = info.cameraModel ?? asset.cameraModel
        updated.indexedLevels.insert(.metadata)
        try store.update(updated)

        // Filenames and folder names are real search signal: people remember
        // "the CLIENT_A interviews" long before they remember what was said.
        let folder = url.deletingLastPathComponent().lastPathComponent
        try store.indexMetadataText(assetID: assetID,
                                    filename: url.lastPathComponent,
                                    folder: folder,
                                    camera: info.cameraDescription)
        return "metadata"
    }

    // MARK: - Level B

    private func processVisual(asset: Asset) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        let encoder = try loadImageEncoder()
        lastVisualWork = Date()

        // A re-index replaces the previous pass rather than doubling every moment.
        try store.deleteMoments(assetID: assetID)

        var totals = CommitTotals()

        if asset.mediaType == .image {
            guard let frame = try KeyframeSampler(options: options.sampler).sampleImage(url: url) else {
                throw IndexerSkip(reason: "could not read image")
            }
            totals += try await commit(assetID: assetID, encoder: encoder,
                                       frames: [frame], endTimes: [0], pinFirst: true)
        } else {
            let duration = asset.durationSeconds ?? 0
            guard duration > 0 else { throw IndexerSkip(reason: "unknown duration — run metadata first") }

            // Keyframes stream in batches. Each frame's moment ends where the
            // next kept frame begins, so the last frame of a batch has to wait
            // for the first frame of the next one before it can be closed.
            var carried: SampledFrame?
            var isFirst = true
            try await KeyframeSampler(options: options.sampler)
                .sampleVideo(url: url, durationSeconds: duration) { batch in
                    var frames = batch
                    if let carried { frames.insert(carried, at: 0) }
                    carried = frames.removeLast()
                    guard !frames.isEmpty, let tail = carried else { return }
                    let ends = Array(frames.dropFirst().map(\.seconds) + [tail.seconds])
                    totals += try await self.commit(assetID: assetID, encoder: encoder,
                                                    frames: frames, endTimes: ends,
                                                    pinFirst: isFirst)
                    isFirst = false
                }
            if let carried {
                totals += try await commit(assetID: assetID, encoder: encoder,
                                           frames: [carried], endTimes: [duration],
                                           pinFirst: isFirst)
            }
        }

        try store.addLevels(.visual, to: assetID)
        _ = try? previews.enforceBudget()

        return totals.ocr > 0
            ? "\(totals.moments) moments, \(totals.ocr) with on-screen text"
            : "\(totals.moments) moments"
    }

    struct CommitTotals {
        var moments = 0
        var ocr = 0

        static func += (lhs: inout CommitTotals, rhs: CommitTotals) {
            lhs.moments += rhs.moments
            lhs.ocr += rhs.ocr
        }
    }

    /// Writes one batch of keyframes: moments, embeddings, ANN entries, previews
    /// and on-screen text — all from images that were decoded exactly once.
    private func commit(assetID: Int64, encoder: MobileCLIPImageEncoder,
                        frames: [SampledFrame], endTimes: [Double],
                        pinFirst: Bool) async throws -> CommitTotals {
        guard !frames.isEmpty else { return CommitTotals() }

        let moments = try store.insertMoments(zip(frames, endTimes).map { frame, end in
            Moment(assetID: assetID, startSeconds: frame.seconds,
                   endSeconds: max(end, frame.seconds),
                   frameHash: Int64(bitPattern: frame.hash))
        })

        let vectors = try encoder.encode(batch: frames.map(\.image))
        let pairs = zip(moments, vectors).compactMap { moment, vector in
            moment.momentID.map { (momentID: $0, vector: vector) }
        }
        try store.saveEmbeddings(pairs, modelID: encoder.modelID)
        try await vectorIndex.add(pairs)

        var totals = CommitTotals(moments: moments.count, ocr: 0)

        for (index, moment) in moments.enumerated() {
            guard let momentID = moment.momentID else { continue }
            let frame = frames[index]

            if options.storeMomentPreviews {
                // The first frame becomes the asset's poster and is pinned: it
                // has to survive cache eviction so an offline drive still shows
                // something. A failed thumbnail never fails the job.
                _ = try? previews.store(frame.image, momentID: momentID,
                                        assetID: assetID, pinned: pinFirst && index == 0)
            }

            // OCR runs on frames we already decoded. Doing it on all 30 frames
            // per second would be absurd; doing it on the ~100 we kept is nearly
            // free, and it catches signs, badges, slates and screens that CLIP
            // reliably misses.
            if options.recognizeText,
               let recognized = try? await TextRecognizer().recognize(frame.image) {
                try store.insertOCR(
                    [OCRText(momentID: momentID, assetID: assetID,
                             text: recognized.text, confidence: recognized.confidence)],
                    momentTimes: [momentID: (moment.startSeconds, moment.endSeconds)])
                totals.ocr += 1
            }
        }
        return totals
    }

    /// Adds OCR to an asset whose visual pass ran before OCR was enabled. Costs a
    /// second decode, which is why the normal path does OCR inline.
    private func processOCRBackfill(asset: Asset) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        let moments = try store.moments(assetID: assetID)
        guard !moments.isEmpty else { throw IndexerSkip(reason: "no moments yet") }

        let recognizer = TextRecognizer()
        let sampler = KeyframeSampler(options: options.sampler)
        var count = 0

        if asset.mediaType == .image {
            guard let frame = try sampler.sampleImage(url: url),
                  let momentID = moments.first?.momentID else {
                throw IndexerSkip(reason: "could not read image")
            }
            if let recognized = try await recognizer.recognize(frame.image) {
                try store.insertOCR(
                    [OCRText(momentID: momentID, assetID: assetID,
                             text: recognized.text, confidence: recognized.confidence)],
                    momentTimes: [momentID: (0, 0)])
                count += 1
            }
        }
        return "\(count) frames with text"
    }

    // MARK: - Level C

    private func processTranscription(asset: Asset) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)

        var transcriberOptions = Transcriber.Options(locale: options.transcriptionLocale)
        transcriberOptions.priority = .background
        let segments = try await Transcriber(options: transcriberOptions).transcribe(url: url)
        guard !segments.isEmpty else { throw IndexerSkip(reason: "no speech found") }

        try store.deleteTranscript(assetID: assetID)
        try store.insertTranscript(segments.map { segment in
            TranscriptChunk(assetID: assetID,
                            startSeconds: segment.startSeconds,
                            endSeconds: segment.endSeconds,
                            text: segment.text,
                            confidence: segment.confidence,
                            locale: options.transcriptionLocale.identifier)
        })
        try store.addLevels(.spoken, to: assetID)
        return "\(segments.count) transcript chunks"
    }

    // MARK: - Idle work

    private func processStrongHash(asset: Asset) throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        var updated = asset
        updated.strongKey = try ContentKey.strong(url: url)
        try store.update(updated)
        return "verified"
    }

    // MARK: - Model lifecycle

    private func loadImageEncoder() throws -> MobileCLIPImageEncoder {
        if let imageEncoder { return imageEncoder }
        let encoder = try MobileCLIPImageEncoder(variant: options.variant)
        imageEncoder = encoder
        try store.register(model: ModelRecord(
            modelID: encoder.modelID, kind: "image-text",
            dimensions: encoder.dimensions, quantization: VectorQuantization.int8.rawValue))
        emit(.modelLoaded(encoder.modelID))
        return encoder
    }

    private func releaseModelsIfIdle(force: Bool) async {
        guard imageEncoder != nil else { return }
        guard force || Date().timeIntervalSince(lastVisualWork) > options.modelIdleTimeout else { return }
        let modelID = imageEncoder?.modelID ?? "?"
        imageEncoder = nil
        emit(.modelReleased(modelID))
    }

    private func emit(_ event: IndexerEvent) {
        onEvent?(event)
    }
}

/// Not an error: a job that legitimately has nothing to do right now (the drive
/// is unplugged, the clip is silent). Marked done rather than retried forever.
struct IndexerSkip: Error {
    let reason: String
}
