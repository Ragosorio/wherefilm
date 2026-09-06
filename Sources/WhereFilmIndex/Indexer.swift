import Foundation
import CoreGraphics
import CoreML
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
        /// Ask Vision's classifier what the frame *is*. Nearly free next to OCR,
        /// and it answers the concrete nouns the smallest CLIP variant is worst
        /// at.
        public var classifyScene = true
        /// Find, describe and cluster faces.
        ///
        /// Off by default, and it should stay that way until somebody turns it
        /// on deliberately. Face vectors are biometric data about people who are
        /// not in the room — an archive is full of them — so this is the one
        /// analysis in the pipeline that is a decision rather than a default.
        public var detectFaces = false
        /// Work out who was speaking. Off by default, Apple silicon only, and
        /// needs a one-time model download somebody asks for.
        public var diarizeSpeakers = false
        /// Languages the text recogniser should expect, and vocabulary it should
        /// prefer. Both nil/empty by default: an archive's own names are the
        /// caller's to supply.
        public var recognitionLanguages: [String]?
        public var customWords: [String] = []
        /// Run the cheap `.fast` screening pass on video keyframes before paying
        /// for `.accurate`. Measured to cost more recall than it saves time.
        public var screenVideoText = false
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
    let budget: WorkBudget
    /// Bounds concurrent full-resolution still decodes — the one step whose
    /// memory is set by the camera that took the picture rather than by us.
    nonisolated static let stillDecodes = DecodeGate()
    public var options: Options
    public var governor: ResourceGovernor

    /// Which descriptor turns a face into a vector. Behind a protocol because
    /// Vision has no face-identity model and the real one has to be installed.
    let faceEmbedder: any FaceEmbedder = FaceEmbedderFactory.best()
    let faceClusterer = FaceClusterer()
    let voiceClusterer = VoiceClusterer()

    private var imageEncoder: MobileCLIPImageEncoder?
    /// Which compute units the resident encoder was built for, so a change in
    /// policy — an editor opening on a Mac with no neural engine — actually
    /// takes effect instead of being noticed and ignored.
    private var loadedComputeUnits: MLComputeUnits?
    private var lastVisualWork = Date.distantPast
    private var activeInteractiveSearches = 0
    /// Progress reporting has to be callable from the nonisolated workers, so it
    /// lives behind a small lock rather than in actor state.
    private let events = EventRelay()

    public init(store: IndexStore,
                vectorIndex: VectorIndex,
                previews: PreviewCache? = nil,
                volumes: VolumeRegistry = VolumeRegistry(),
                options: Options = Options(),
                governor: ResourceGovernor = ResourceGovernor(),
                budget: WorkBudget = .shared) {
        self.store = store
        self.vectorIndex = vectorIndex
        self.previews = previews ?? PreviewCache(store: store)
        self.volumes = volumes
        self.options = options
        self.governor = governor
        self.budget = budget
    }

    public func setEventHandler(_ handler: @escaping @Sendable (IndexerEvent) -> Void) {
        events.set(handler)
    }

    public func setGovernorSettings(_ settings: ResourceGovernor.Settings) {
        governor.settings = settings
    }

    /// Turns face analysis on or off while the indexer is running.
    ///
    /// It is opt-in, so the answer changes at the moment somebody decides — not
    /// at launch, which is when the options were fixed.
    public func setDetectFaces(_ enabled: Bool) {
        options.detectFaces = enabled
    }

    public func setDiarizeSpeakers(_ enabled: Bool) {
        options.diarizeSpeakers = enabled
    }

    /// Interactive reads always outrank background enrichment. In-flight work
    /// is allowed to finish safely; no new wave starts until every overlapping
    /// search has ended.
    public func beginInteractiveSearch() {
        activeInteractiveSearches += 1
    }

    public func endInteractiveSearch() {
        activeInteractiveSearches = max(0, activeInteractiveSearches - 1)
    }

    var isInteractiveSearchActive: Bool { activeInteractiveSearches > 0 }

    // MARK: - Loop

    /// Runs until cancelled. Honours the governor between every single job, so
    /// pressing Pause takes effect at the next job boundary rather than at the
    /// end of a three-hour transcription queue.
    public func run() async {
        try? store.requeueStaleJobs()
        try? await vectorIndex.openForWriting()

        while !Task.isCancelled {
            if activeInteractiveSearches > 0 {
                emit(.throttled(.searchActive))
                // Poll quickly: a typical search is far shorter than the normal
                // five-second idle interval, and indexing should resume as soon
                // as the user-visible work is done.
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let decision = governor.decide()
            guard decision.isWorking else {
                emit(.throttled(decision.reason))
                await releaseModelsIfIdle(force: true)
                try? await Task.sleep(for: .seconds(options.idlePollSeconds))
                continue
            }

            let didWork = await runWave(allowedTasks: decision.allowedTasks,
                                        concurrency: decision.concurrency)
            if !didWork {
                // Smart mode can allow only metadata while on battery or under
                // thermal pressure. Once that subset is empty, the queue is not
                // truly idle: heavier work is being deferred for a reason.
                if decision.reason == .none {
                    emit(.idle)
                } else {
                    emit(.throttled(decision.reason))
                }
                await releaseModelsIfIdle(force: true)
                try? await vectorIndex.save()
                try? await Task.sleep(for: .seconds(options.idlePollSeconds))
            } else {
                await releaseModelsIfIdle(force: false)
            }
        }

        try? await vectorIndex.save()
    }

    /// Runs up to `concurrency` jobs at once and returns whether any ran.
    ///
    /// This is the difference between a governor that *says* "2 at a time" and
    /// one that means it. The previous loop called `runOnce` in sequence and
    /// discarded `decision.concurrency` entirely, so an eight-core Mac indexed
    /// one file at a time and measured 23% CPU — three quarters of the machine
    /// sat idle waiting on Vision and AVFoundation.
    @discardableResult
    func runWave(allowedTasks: [JobTask], concurrency: Int) async -> Bool {
        let options = self.options
        let width = max(1, concurrency)
        if width == 1 { return await runOnce(allowedTasks: allowedTasks, options: options) }

        return await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<width {
                group.addTask { await self.runOnce(allowedTasks: allowedTasks, options: options) }
            }
            var any = false
            for await didWork in group { any = any || didWork }
            return any
        }
    }

    /// Processes at most one job. Returns false when the queue had nothing to do.
    @discardableResult
    nonisolated public func runOnce(allowedTasks: [JobTask], options: Options) async -> Bool {
        guard let job = (try? store.claimNextJob(tasks: allowedTasks)) ?? nil else { return false }
        guard let asset = try? store.asset(id: job.assetID) else {
            try? store.fail(job: job, error: "asset vanished")
            return true
        }

        emit(.started(assetID: job.assetID, task: job.task, name: asset.displayName))
        do {
            let detail = try await process(job: job, asset: asset, options: options)
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
    public func drain(allowedTasks: [JobTask] = JobTask.allCases, limit: Int = .max,
                      concurrency: Int? = nil, honorGovernor: Bool = false) async -> Int {
        try? store.requeueStaleJobs()
        try? await vectorIndex.openForWriting()
        let width = max(1, concurrency ?? governor.decide().concurrency)
        let options = self.options
        var processed = 0
        while processed < limit, !Task.isCancelled {
            let decision = governor.decide()
            let permitted = honorGovernor ? allowedTasks.filter(decision.allowedTasks.contains) : allowedTasks
            guard !permitted.isEmpty else { break }
            let currentWidth = honorGovernor ? min(width, decision.concurrency) : width
            guard currentWidth > 0 else { break }
            // Never start more workers than jobs we are still allowed to run.
            let wave = min(currentWidth, limit - processed)
            let done = await withTaskGroup(of: Bool.self) { group -> Int in
                for _ in 0..<wave {
                    group.addTask { await self.runOnce(allowedTasks: permitted, options: options) }
                }
                var count = 0
                for await didWork in group where didWork { count += 1 }
                return count
            }
            guard done > 0 else { break }
            processed += done
        }
        try? await vectorIndex.save()
        await releaseModelsIfIdle(force: true)
        return processed
    }

    // MARK: - Job dispatch

    nonisolated private func process(job: Job, asset: Asset, options: Options) async throws -> String {
        // Reserve the memory this job is about to hold *before* decoding
        // anything, so peak usage is a property of the budget rather than of
        // whatever happens to be queued. Metadata and hashing never materialise
        // a frame and are not charged at all.
        let cost = frameCost(task: job.task, asset: asset, options: options)
        guard cost > 0 else { return try await runUncharged(job: job, asset: asset, options: options) }
        return try await budget.run(cost: cost) {
            try await self.runUncharged(job: job, asset: asset, options: options)
        }
    }

    nonisolated private func runUncharged(job: Job, asset: Asset, options: Options) async throws -> String {
        switch job.task {
        case .metadata: try await processMetadata(asset: asset)
        case .visual: try await processVisual(asset: asset, options: options)
        case .ocr: try await processOCRBackfill(asset: asset, options: options)
        case .transcribe: try await processTranscription(asset: asset, options: options)
        case .diarize: try await processDiarization(asset: asset, options: options)
        case .strongHash: try processStrongHash(asset: asset)
        }
    }

    /// How many decoded keyframes this job keeps alive for its whole duration.
    ///
    /// A video pass holds a full sampler batch plus the frame carried across the
    /// batch boundary; a photograph holds the single 1024 px frame it produced.
    /// The full-resolution buffer a still needs *while decoding* is much larger
    /// but momentary, so it is bounded separately by `stillDecodes` rather than
    /// charged here — charging the spike for the whole job serialised the photo
    /// queue and made a 203-image library five times slower.
    nonisolated private func frameCost(task: JobTask, asset: Asset, options: Options) -> Int {
        switch task {
        case .metadata, .strongHash:
            0
        case .visual, .ocr:
            asset.mediaType == .image ? 1 : options.sampler.batchSize + 1
        case .transcribe:
            // No frames, but bounded PCM streaming through SpeechAnalyzer still
            // deserves to be counted so audio and video share one ceiling.
            4
        case .diarize:
            // Streams from disk in chunks like transcription, and holds model
            // buffers of its own while it does.
            4
        }
    }

    /// Resolves an asset to a readable file, or explains why it can't be reached.
    /// An offline drive is not an error — it's a "come back later".
    nonisolated private func onlineURL(for assetID: Int64) throws -> URL {
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

    nonisolated private func processMetadata(asset: Asset) async throws -> String {
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

    nonisolated private func processVisual(asset: Asset, options: Options) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let screenText = options.screenVideoText
        let url = try onlineURL(for: assetID)
        let encoder = try await loadImageEncoder()

        // A re-index replaces the previous pass rather than doubling every moment.
        // The SQLite cascade removes stored embeddings, but the USearch file is
        // derived and has to be told about the old keys explicitly or every
        // refresh leaves invisible dead vectors behind.
        let oldMomentIDs = try store.moments(assetID: assetID).compactMap(\.momentID)
        for momentID in oldMomentIDs { try? await vectorIndex.remove(momentID: momentID) }
        if options.detectFaces { try store.deleteFaces(assetID: assetID) }
        try store.deleteMoments(assetID: assetID)

        var totals = CommitTotals()

        if asset.mediaType == .image {
            // ImageIO must materialise the full-resolution image before it can
            // return a 1024 px thumbnail, so a 12-megapixel still briefly costs
            // about 48 MB. Twelve workers doing that at once pushed peak memory
            // 61% above the old build; a handful at a time costs nothing
            // measurable and keeps the ceiling where it was.
            let sampler = KeyframeSampler(options: options.sampler)
            guard let frame = try await Self.stillDecodes.run({ try sampler.sampleImage(url: url) })
            else {
                throw IndexerSkip(reason: "could not read image")
            }
            totals += try await commit(assetID: assetID, encoder: encoder, options: options,
                                       frames: [frame], endTimes: [0], pinFirst: true,
                                       screenText: false)
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
                                                    options: options,
                                                    frames: frames, endTimes: ends,
                                                    pinFirst: isFirst, screenText: screenText)
                    isFirst = false
                }
            if let carried {
                totals += try await commit(assetID: assetID, encoder: encoder, options: options,
                                           frames: [carried], endTimes: [duration],
                                           pinFirst: isFirst, screenText: screenText)
            }
        }

        if options.detectFaces {
            // Appearances are rebuilt from the faces of the whole asset, not
            // accumulated per batch: an interval only means something once every
            // frame it spans has been seen.
            let faces = try store.faces(assetID: assetID)
            try store.replaceAppearances(
                assetID: assetID, AppearanceBuilder.intervals(from: faces, assetID: assetID))
        }

        try store.addLevels(.visual, to: assetID)
        _ = try? previews.enforceBudget()

        var detail = "\(totals.moments) moments"
        if totals.ocr > 0 { detail += ", \(totals.ocr) with on-screen text" }
        if totals.labels > 0 { detail += ", \(totals.labels) labels" }
        if totals.faces > 0 { detail += ", \(totals.faces) faces" }
        return detail
    }

    struct CommitTotals {
        var moments = 0
        var ocr = 0
        var labels = 0
        var faces = 0

        static func += (lhs: inout CommitTotals, rhs: CommitTotals) {
            lhs.moments += rhs.moments
            lhs.ocr += rhs.ocr
            lhs.labels += rhs.labels
            lhs.faces += rhs.faces
        }
    }

    /// Crops, gates and embeds the faces found in one frame.
    ///
    /// The gate is doing most of the work here. Real footage is full of faces
    /// that are thirty pixels wide, motion-blurred or turned away, and embedding
    /// those is not merely wasted effort: they land between clusters and are
    /// precisely how one person ends up scattered across a dozen of them.
    nonisolated static func describeFaces(
        _ faces: [DetectedFace], in image: CGImage, momentID: Int64, assetID: Int64,
        seconds: Double, embedder: any FaceEmbedder
    ) async -> [FaceRow] {
        var rows: [FaceRow] = []
        for face in faces {
            guard FaceCrop.isWorthEmbedding(face, frameWidth: image.width) else { continue }
            // Aligned when the eyes were found, cropped when they were not. The
            // aligned path is the one that does not merge two people; the crop
            // is a usable second best rather than a failure.
            let prepared: CGImage?
            if let left = face.leftEye, let right = face.rightEye {
                prepared = FaceCrop.align(
                    image,
                    leftEye: CGPoint(x: left.x * Double(image.width),
                                     y: left.y * Double(image.height)),
                    rightEye: CGPoint(x: right.x * Double(image.width),
                                      y: right.y * Double(image.height)))
                    ?? FaceCrop.cut(face, from: image)
            } else {
                prepared = FaceCrop.cut(face, from: image)
            }
            guard let crop = prepared,
                  let vector = try? await embedder.embed(crop) else { continue }
            let encoded = VectorCodec.encodeInt8(vector)
            rows.append(FaceRow(
                momentID: momentID, assetID: assetID, seconds: seconds,
                x: face.x, y: face.y, width: face.width, height: face.height,
                quality: face.quality, roll: face.roll, yaw: face.yaw, pitch: face.pitch,
                modelID: embedder.modelID, dimensions: vector.count,
                quantization: VectorQuantization.int8.rawValue, scale: encoded.scale,
                vector: encoded.data))
        }
        return rows
    }

    /// Recorded with every label, so a future taxonomy can be told apart from
    /// this one instead of silently mixed with it.
    static let sceneClassifierID = "vision-classify-v2"

    /// Writes one batch of keyframes: moments, embeddings, ANN entries, previews
    /// and on-screen text — all from images that were decoded exactly once.
    nonisolated private func commit(assetID: Int64, encoder: MobileCLIPImageEncoder, options: Options,
                        frames: [SampledFrame], endTimes: [Double],
                        pinFirst: Bool, screenText: Bool) async throws -> CommitTotals {
        guard !frames.isEmpty else { return CommitTotals() }

        let moments = try store.insertMoments(zip(frames, endTimes).map { frame, end in
            Moment(assetID: assetID, startSeconds: frame.seconds,
                   endSeconds: max(end, frame.seconds),
                   frameHash: Int64(bitPattern: frame.hash))
        })

        // Core ML blocks its thread while the neural engine works, and Vision
        // crashes if it is running underneath. Both problems have one answer:
        // take the image-analysis gate exclusively for the duration.
        let images = frames.map(\.image)
        let vectors = try await VisionGate.shared.runExclusive { try encoder.encode(batch: images) }
        let pairs = zip(moments, vectors).compactMap { moment, vector in
            moment.momentID.map { (momentID: $0, vector: vector) }
        }
        try store.saveEmbeddings(pairs, modelID: encoder.modelID)
        try await vectorIndex.add(pairs)

        var totals = CommitTotals(moments: moments.count, ocr: 0)

        if options.storeMomentPreviews {
            // The first frame becomes the asset's poster and is pinned: it has
            // to survive cache eviction so an offline drive still shows
            // something. A failed thumbnail never fails the job. Persist all
            // rows in one transaction after encoding the batch.
            let pending = moments.enumerated().compactMap { index, moment in
                moment.momentID.map {
                    PreviewCache.PendingPreview(
                        image: frames[index].image,
                        momentID: $0,
                        assetID: assetID,
                        pinned: pinFirst && index == 0)
                }
            }
            _ = try? previews.store(pending)
        }

        // OCR runs on frames we already decoded. Doing it on all 30 frames per
        // second would be absurd; doing it on the ~100 we kept is nearly free,
        // and it catches signs, badges, slates and screens that CLIP reliably
        // misses. The whole batch goes at once — one frame at a time left the
        // machine idle waiting on Vision.
        if options.recognizeText || options.classifyScene || options.detectFaces {
            // One pass over the frames answers every question about them. When
            // helpers are available this is also one process hop per frame
            // instead of three, because moving the frame is the expensive part.
            var analyzerOptions = FrameAnalyzer.Options()
            analyzerOptions.recognizesText = options.recognizeText
            analyzerOptions.classifiesScene = options.classifyScene
            analyzerOptions.detectsFaces = options.detectFaces
            analyzerOptions.screensFirst = screenText
            analyzerOptions.recognitionLanguages = options.recognitionLanguages
            analyzerOptions.customWords = options.customWords
            let analyses = await FrameAnalyzer(options: analyzerOptions)
                .analyze(batch: frames.map(\.image))

            var ocrRows: [OCRText] = []
            var labelRows: [LabelRow] = []
            var faceRows: [FaceRow] = []
            var times: [Int64: (Double, Double)] = [:]
            for (index, moment) in moments.enumerated() {
                guard let momentID = moment.momentID, index < analyses.count else { continue }
                let analysis = analyses[index]
                guard !analysis.isEmpty else { continue }
                times[momentID] = (moment.startSeconds, moment.endSeconds)
                if options.detectFaces, !analysis.faces.isEmpty {
                    faceRows += await Self.describeFaces(
                        analysis.faces, in: frames[index].image, momentID: momentID,
                        assetID: assetID, seconds: frames[index].seconds,
                        embedder: faceEmbedder)
                }
                if let hit = analysis.text {
                    ocrRows.append(OCRText(momentID: momentID, assetID: assetID,
                                           text: hit.text, confidence: hit.confidence))
                }
                for label in analysis.labels where label.confidence >= Double(analyzerOptions.minimumLabelConfidence) {
                    labelRows.append(LabelRow(momentID: momentID, assetID: assetID,
                                              identifier: label.identifier,
                                              confidence: label.confidence,
                                              source: Self.sceneClassifierID))
                }
            }
            if !ocrRows.isEmpty {
                try store.insertOCR(ocrRows, momentTimes: times)
                totals.ocr = ocrRows.count
            }
            if !labelRows.isEmpty {
                try store.insertLabels(labelRows, momentTimes: times)
                totals.labels = labelRows.count
            }
            if !faceRows.isEmpty {
                let stored = try store.insertFaces(faceRows)
                try await faceClusterer.assign(faces: stored, store: store)
                totals.faces = stored.count
            }
        }
        return totals
    }

    /// Adds OCR to an asset whose visual pass ran before OCR was enabled. Costs a
    /// second decode, which is why the normal path does OCR inline.
    ///
    /// Videos used to fall straight through this function and report "0 frames
    /// with text" — the job was marked done without a single frame being read,
    /// so backfilling on-screen text over an existing library silently did
    /// nothing at all.
    nonisolated private func processOCRBackfill(asset: Asset, options: Options) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        let moments = try store.moments(assetID: assetID)
        guard !moments.isEmpty else { throw IndexerSkip(reason: "no moments yet") }

        var videoOptions = TextRecognizer.Options()
        videoOptions.screensFirst = options.screenVideoText
        let recognizer = TextRecognizer(options: videoOptions)
        let sampler = KeyframeSampler(options: options.sampler)

        if asset.mediaType == .image {
            guard let frame = try sampler.sampleImage(url: url),
                  let momentID = moments.first?.momentID else {
                throw IndexerSkip(reason: "could not read image")
            }
            // A single photo: the cheap screening pass buys nothing, so skip it.
            var direct = TextRecognizer.Options()
            direct.screensFirst = false
            let recognized = try await TextRecognizer(options: direct).recognize(frame.image)
            let rows = recognized.map {
                [OCRText(momentID: momentID, assetID: assetID,
                         text: $0.text, confidence: $0.confidence)]
            } ?? []
            try store.replaceOCR(assetID: assetID, texts: rows,
                                 momentTimes: [momentID: (0, 0)])
            return rows.isEmpty ? "no text found" : "1 frame with text"
        }

        // Video: re-decode exactly the moments the visual pass already chose, so
        // backfilled text lands on the same timeline the search results use.
        let duration = asset.durationSeconds ?? 0
        guard duration > 0 else { throw IndexerSkip(reason: "unknown duration — run metadata first") }

        // Moments are keyed by their start time; match decoded frames back to
        // them by nearest start rather than by position, because the sampler is
        // free to land on a neighbouring keyframe.
        let byStart = moments.compactMap { moment -> (Double, Int64, Double, Double)? in
            moment.momentID.map { (moment.startSeconds, $0, moment.startSeconds, moment.endSeconds) }
        }.sorted { $0.0 < $1.0 }
        guard !byStart.isEmpty else { throw IndexerSkip(reason: "no moments yet") }

        var allRows: [OCRText] = []
        var allTimes: [Int64: (Double, Double)] = [:]
        try await sampler.sampleVideo(url: url, durationSeconds: duration) { batch in
            let hits = await recognizer.recognize(batch: batch.map(\.image))
            for (index, frame) in batch.enumerated() {
                guard index < hits.count, let hit = hits[index] else { continue }
                // Nearest moment by start time. Binary search matters for the
                // 4,000-frame safety ceiling: a linear scan here turned a long
                // video backfill into up to sixteen million comparisons.
                guard let match = Self.nearestMoment(to: frame.seconds, in: byStart)
                else { continue }
                allRows.append(OCRText(momentID: match.1, assetID: assetID,
                                       text: hit.text, confidence: hit.confidence))
                allTimes[match.1] = (match.2, match.3)
            }
        }
        try store.replaceOCR(assetID: assetID, texts: allRows, momentTimes: allTimes)
        return "\(allRows.count) frames with text"
    }

    private static func nearestMoment(
        to seconds: Double,
        in moments: [(Double, Int64, Double, Double)]
    ) -> (Double, Int64, Double, Double)? {
        guard !moments.isEmpty else { return nil }
        var lower = 0
        var upper = moments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if moments[middle].0 < seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        if lower == 0 { return moments[0] }
        if lower == moments.count { return moments[moments.count - 1] }
        let before = moments[lower - 1]
        let after = moments[lower]
        return seconds - before.0 <= after.0 - seconds ? before : after
    }

    // MARK: - Level C

    nonisolated private func processTranscription(asset: Asset, options: Options) async throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)

        var transcriberOptions = Transcriber.Options(locale: options.transcriptionLocale)
        transcriberOptions.priority = .background
        let transcriber = Transcriber(options: transcriberOptions)
        // Resolved before the work, so the answer can be stored with the result
        // and reported in the event even when the run finds nothing.
        let engine = await transcriber.resolvedEngine()
        let segments = try await transcriber.transcribe(url: url)
        guard !segments.isEmpty else { throw IndexerSkip(reason: "no speech found") }

        try store.deleteTranscript(assetID: assetID)
        try store.insertTranscript(segments.map { segment in
            TranscriptChunk(assetID: assetID,
                            startSeconds: segment.startSeconds,
                            endSeconds: segment.endSeconds,
                            text: segment.text,
                            confidence: segment.confidence,
                            locale: options.transcriptionLocale.identifier,
                            engine: engine?.identifier)
        })
        try store.addLevels(.spoken, to: assetID)
        let suffix = engine.map { $0.name == "SpeechTranscriber" ? "" : " (\($0.name))" } ?? ""
        return "\(segments.count) transcript chunks\(suffix)"
    }

    /// Who spoke, and where that puts them.
    ///
    /// Runs only when asked for. Diarization is the one analysis whose models are
    /// not already on the machine, so an indexer that reached for the network on
    /// its own would break a promise the rest of the product keeps.
    nonisolated private func processDiarization(asset: Asset, options: Options) async throws -> String {
        guard options.diarizeSpeakers else { throw IndexerSkip(reason: "speaker analysis is off") }
        guard Diarizer.isSupported else {
            throw IndexerSkip(reason: "speaker analysis needs Apple silicon")
        }
        guard Diarizer.isInstalled else {
            throw IndexerSkip(reason: "speaker models are not installed — run `wherefilm voices install`")
        }
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)

        let segments = try await Diarizer().diarize(url: url)
        guard !segments.isEmpty else { throw IndexerSkip(reason: "no speech found") }

        let stored = try store.replaceVoiceSegments(assetID: assetID, segments.map { segment in
            let encoded = VectorCodec.encodeInt8(segment.embedding)
            return VoiceSegment(
                assetID: assetID, startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds, localSpeaker: segment.localSpeaker,
                modelID: Diarizer.modelID, dimensions: segment.embedding.count,
                scale: encoded.scale, vector: encoded.data, confidence: segment.quality)
        })
        try await voiceClusterer.assign(segments: stored, store: store)

        // Appearances by voice sit in the same table as appearances by face, so
        // "where does this person appear" and "where do they speak" are one
        // query. Only voices already linked to a person contribute; an unlinked
        // voice is a speaker nobody has identified yet.
        let linked = try store.voices().reduce(into: [Int64: Int64]()) { map, voice in
            if let voiceID = voice.voiceID, let personID = voice.personID {
                map[voiceID] = personID
            }
        }
        if !linked.isEmpty {
            let refreshed = try store.voiceSegments(assetID: assetID)
            let spoken = SpokenAppearanceBuilder.intervals(
                from: refreshed, assetID: assetID, personOf: linked)
            let faces = try store.appearances(assetID: assetID).filter { $0.source != "voice" }
            try store.replaceAppearances(assetID: assetID, faces + spoken)
        }

        let speakers = Set(stored.map(\.localSpeaker)).count
        return "\(stored.count) speech segments · \(speakers) speakers"
    }

    // MARK: - Idle work

    nonisolated private func processStrongHash(asset: Asset) throws -> String {
        guard let assetID = asset.assetID else { throw IndexerSkip(reason: "no id") }
        let url = try onlineURL(for: assetID)
        var updated = asset
        updated.strongKey = try ContentKey.strong(url: url)
        try store.update(updated)
        return "verified"
    }

    // MARK: - Model lifecycle

    private func loadImageEncoder() throws -> MobileCLIPImageEncoder {
        lastVisualWork = Date()
        // Compute units are fixed when a model is loaded, so a change of policy
        // means a reload. That is free here by construction: workers are
        // disposable and the encoder is released after every idle gap anyway.
        let units = ComputePolicy.imageEncoding(editorRunning: governor.isEditorRunning())
        if let imageEncoder, loadedComputeUnits == units { return imageEncoder }
        let encoder = try MobileCLIPImageEncoder(variant: options.variant, computeUnits: units)
        imageEncoder = encoder
        loadedComputeUnits = units
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
        loadedComputeUnits = nil
        emit(.modelReleased(modelID))
    }

    nonisolated private func emit(_ event: IndexerEvent) {
        events.send(event)
    }
}

/// Carries progress out of the nonisolated workers.
///
/// The handler used to be actor state, which meant every `→ visual: NAME` line
/// was a hop onto the indexer's serial executor — the exact thing the workers
/// now exist to avoid.
final class EventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (IndexerEvent) -> Void)?

    func set(_ handler: @escaping @Sendable (IndexerEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func send(_ event: IndexerEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }
}

/// Not an error: a job that legitimately has nothing to do right now (the drive
/// is unplugged, the clip is silent). Marked done rather than retried forever.
struct IndexerSkip: Error {
    let reason: String
}
