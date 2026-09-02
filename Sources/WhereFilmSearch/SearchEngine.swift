import Foundation
import GRDB
import WhereFilmCore
import WhereFilmML

/// Why a result matched. Never show a bare percentage: when the answer is
/// slightly wrong, seeing *which* signal fired is what makes it usable.
public enum Evidence: Sendable {
    case visual(similarity: Float, phrase: String)
    case transcript(text: String, seconds: Double)
    case onScreenText(text: String)
    case metadata(text: String, kind: SearchTextKind)

    public var label: String {
        switch self {
        case .visual(let similarity, let phrase):
            "visual · \"\(phrase)\" · cos \(String(format: "%.3f", similarity))"
        case .transcript(let text, let seconds):
            "dialogue · \(SearchResult.timecode(seconds)) · \"\(text.prefix(90))\""
        case .onScreenText(let text): "on-screen text · \"\(text.prefix(60))\""
        case .metadata(let text, let kind): "\(kind.rawValue) · \(text.prefix(60))"
        }
    }
}

public struct ResolvedLocation: Sendable {
    public let volumeName: String
    public let volumeUUID: String
    public let relativePath: String
    public let availability: Availability
    /// Non-nil only when the drive is actually mounted right now.
    public let url: URL?

    public var summary: String {
        switch availability {
        case .online: "\(volumeName) · online"
        case .offline: "\(volumeName) · offline"
        case .moved: "\(volumeName) · moved"
        case .missing: "\(volumeName) · original missing"
        }
    }
}

public struct SearchResult: Sendable {
    public let assetID: Int64
    public let momentID: Int64?
    public let displayName: String
    public let mediaType: MediaType
    public let startSeconds: Double
    public let endSeconds: Double
    public let score: Double
    public let evidence: [Evidence]
    public let locations: [ResolvedLocation]
    public let previewPath: URL?
    public let createdAt: Date?
    public let durationSeconds: Double?

    public var bestLocation: ResolvedLocation? {
        locations.min { lhs, rhs in rank(lhs.availability) < rank(rhs.availability) }
    }

    private func rank(_ availability: Availability) -> Int {
        switch availability {
        case .online: 0
        case .offline: 1
        case .moved: 2
        case .missing: 3
        }
    }

    public var timeRange: String {
        mediaType == .image
            ? "—"
            : "\(Self.timecode(startSeconds))–\(Self.timecode(endSeconds))"
    }

    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

public enum SearchPhase: String, Sendable {
    case fast
    case refined
}

/// Where the time in one search actually went.
///
/// Without this, tuning is guesswork: the first attempt at a prefix guard in
/// this file made two of three benchmark queries *slower*, because the "cheap"
/// lookup it added was a full scan of the text index. A stage breakdown turns
/// that from a puzzle into a line of output.
public struct SearchTimings: Sendable {
    public private(set) var stages: [(name: String, milliseconds: Double)] = []

    public init() {}

    mutating func record(_ name: String, since start: DispatchTime) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        stages.append((name, elapsed))
    }

    public var summary: String {
        stages
            .map { "\($0.name) \(String(format: "%.2f", $0.milliseconds)) ms" }
            .joined(separator: " · ")
    }
}

/// One stable snapshot in a progressive search. The fast snapshot comes from
/// FTS/metadata; the refined snapshot adds visual ANN and multimodal fusion.
public struct SearchUpdate: Sendable {
    public let phase: SearchPhase
    public let results: [SearchResult]
    public let elapsedMilliseconds: Double
    public let isFinal: Bool
    public var timings = SearchTimings()
}

/// Runs each channel independently and then fuses them.
///
/// The important idea is that no single embedding is asked to understand
/// "the guy in the blue shirt who talked about the budget". Vision answers the
/// appearance half, the transcript answers the speech half, and the fact that
/// they agree *within the same file, seconds apart* is what produces a confident
/// answer. Two mediocre signals that coincide beat one great signal alone — and
/// it costs a fraction of asking a large video model to watch thirty minutes.
public struct SearchEngine: Sendable {
    public struct Weights: Sendable {
        public var visual = 0.45
        public var transcript = 0.35
        public var onScreenText = 0.12
        public var metadata = 0.08
        /// Added when two different channels agree inside `temporalWindow`.
        public var agreementBonus = 0.35
        /// How close in time two signals must be to count as the same moment.
        public var temporalWindow: Double = 30
        /// Overrides the model's own similarity calibration. Normally nil: the
        /// scale belongs to the model, not to the ranking.
        ///
        /// The floor matters more than it looks. Rank-relative scoring alone
        /// would happily report the best of nine bad matches as "100%", which is
        /// exactly the kind of confident nonsense that destroys trust in a search
        /// tool. Cosine similarity is an absolute scale, so it is treated as one.
        public var minimumVisualSimilarity: Float?
        public var strongVisualSimilarity: Float?

        public init() {}
    }

    public struct Options: Sendable {
        public var limit = 20
        /// How deep to look in each channel before fusing. Wider than `limit`,
        /// because a result that wins on agreement may be mid-pack in both
        /// channels individually.
        public var channelDepth = 300
        public var weights = Weights()
        public var variant: MobileCLIPVariant = .s0
        /// Collapse near-identical frames from the same asset.
        public var suppressNearDuplicates = true
        /// Drop results whose final confidence is below this, on the same 0–1
        /// scale the interface shows as a percentage.
        ///
        /// The similarity floor above decides what may *enter* the ranking; this
        /// decides what is worth *showing*. They are different questions. A
        /// result the engine itself rates at 2% is not an answer, and printing it
        /// next to a genuine 27% match teaches someone to distrust both numbers.
        public var minimumConfidence: Double = 0

        public init() {}
    }

    let store: IndexStore
    let volumes: VolumeRegistry
    private let embeddingProvider: any QueryEmbeddingProviding
    public var options: Options

    public init(store: IndexStore, volumes: VolumeRegistry = VolumeRegistry(),
                options: Options = Options()) {
        self.store = store
        self.volumes = volumes
        self.embeddingProvider = QueryEmbeddingCache.shared
        self.options = options
    }

    init(store: IndexStore, volumes: VolumeRegistry = VolumeRegistry(),
         options: Options = Options(),
         embeddingProvider: any QueryEmbeddingProviding) {
        self.store = store
        self.volumes = volumes
        self.embeddingProvider = embeddingProvider
        self.options = options
    }

    var visualFloor: Float {
        options.weights.minimumVisualSimilarity ?? options.variant.similarityFloor
    }

    var visualCeiling: Float {
        options.weights.strongVisualSimilarity ?? options.variant.similarityCeiling
    }

    public func search(plan: SearchPlan, vectorIndex: VectorIndex?) async throws -> [SearchResult] {
        let text = try textCandidates(plan: plan)
        let visual = try await visualCandidates(plan: plan, vectorIndex: vectorIndex)
        try Task.checkCancellation()
        return try build(results: fuse(text + visual))
    }

    /// The part of search that never needs Core ML or the vector index.
    public func searchFast(plan: SearchPlan) throws -> [SearchResult] {
        try build(results: fuse(textCandidates(plan: plan)))
    }

    /// Publishes useful text/metadata matches first and a fully fused ranking
    /// later. Cancelling the consuming task cancels the work behind the stream.
    public func searchProgressively(
        plan: SearchPlan,
        vectorIndex: VectorIndex?
    ) -> AsyncThrowingStream<SearchUpdate, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let started = Date()
                var timings = SearchTimings()
                var mark = DispatchTime.now()
                do {
                    try Task.checkCancellation()
                    let text = try textCandidates(plan: plan)
                    timings.record("text", since: mark); mark = DispatchTime.now()
                    let fused = fuse(text)
                    timings.record("fuse", since: mark); mark = DispatchTime.now()
                    let fast = try build(results: fused)
                    timings.record("hydrate", since: mark); mark = DispatchTime.now()
                    try Task.checkCancellation()

                    let hasRefinement = plan.hasVisualSignal
                    continuation.yield(SearchUpdate(
                        phase: .fast,
                        results: fast,
                        elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000,
                        isFinal: !hasRefinement,
                        timings: timings
                    ))

                    guard hasRefinement else {
                        continuation.finish()
                        return
                    }

                    let visual = try await visualCandidates(
                        plan: plan, vectorIndex: vectorIndex, timings: &timings)
                    mark = DispatchTime.now()
                    try Task.checkCancellation()
                    let refinedFusion = fuse(text + visual)
                    timings.record("fuse2", since: mark); mark = DispatchTime.now()
                    let refined = try build(results: refinedFusion)
                    timings.record("hydrate2", since: mark)
                    try Task.checkCancellation()
                    continuation.yield(SearchUpdate(
                        phase: .refined,
                        results: refined,
                        elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000,
                        isFinal: true,
                        timings: timings
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    // MARK: - Channels

    private struct Candidate {
        var assetID: Int64
        var momentID: Int64?
        var seconds: Double
        var endSeconds: Double
        var channel: Channel
        var rawScore: Double
        var evidence: Evidence
    }

    private enum Channel: Hashable {
        case visual, transcript, ocr, metadata
    }

    private func visualCandidates(plan: SearchPlan, vectorIndex: VectorIndex?) async throws -> [Candidate] {
        var ignored = SearchTimings()
        return try await visualCandidates(plan: plan, vectorIndex: vectorIndex, timings: &ignored)
    }

    private func visualCandidates(plan: SearchPlan, vectorIndex: VectorIndex?,
                                  timings: inout SearchTimings) async throws -> [Candidate] {
        guard plan.hasVisualSignal else { return [] }
        var mark = DispatchTime.now()

        let query: [Float]
        do {
            query = try await embeddingProvider.embedding(
                for: plan.visualPhrases,
                variant: options.variant
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No visual model installed yet: text search still works. Degrading
            // is better than failing.
            return []
        }
        timings.record("encode", since: mark); mark = DispatchTime.now()
        guard !query.isEmpty else { return [] }
        try Task.checkCancellation()

        let hits: [VectorIndex.Hit]
        if let vectorIndex, await vectorIndex.count > 0 {
            hits = try await vectorIndex.search(query, limit: options.channelDepth)
        } else {
            // Exact scan. Slower at millions of moments, but correct — and
            // perfectly fine for a library that hasn't been graph-indexed yet.
            hits = try LinearVectorSearch.search(
                store: store, modelID: options.variant.modelID,
                query: query, limit: options.channelDepth)
        }

        timings.record("ann", since: mark); mark = DispatchTime.now()
        let usable = hits.filter { $0.similarity >= visualFloor }
        let moments = try store.moments(ids: usable.map(\.momentID))
        timings.record("moments", since: mark)
        let phrase = plan.visualPhrases.first ?? plan.rawQuery
        return usable.compactMap { hit in
            guard let moment = moments[hit.momentID] else { return nil }
            return Candidate(
                assetID: moment.assetID, momentID: hit.momentID,
                seconds: moment.startSeconds, endSeconds: moment.endSeconds,
                channel: .visual, rawScore: Double(hit.similarity),
                evidence: .visual(similarity: hit.similarity, phrase: phrase))
        }
    }

    private static let ocrKinds: [SearchTextKind] = [.ocr]
    private static let metadataKinds: [SearchTextKind] = [.filename, .folder, .metadata, .note]

    private func textCandidates(plan: SearchPlan) throws -> [Candidate] {
        var candidates: [Candidate] = []
        let breadth = PrefixBudget(store: store)

        let spokenPattern = plan.spokenTerms.isEmpty
            ? nil : Self.ftsPattern(for: plan.spokenTerms, budget: breadth)
        let literalPattern = plan.literalTerms.isEmpty
            ? nil : Self.ftsPattern(for: plan.literalTerms, budget: breadth)

        // The transcript channel and the literal channels usually run the same
        // words. When they do, they are one MATCH and one bm25 pass, split three
        // ways — not three identical scans of the same index.
        if let literalPattern, literalPattern == spokenPattern {
            let groups = try store.textSearch(
                pattern: literalPattern,
                groups: [[.transcript], Self.ocrKinds, Self.metadataKinds],
                limitPerGroup: options.channelDepth)
            candidates += transcriptCandidates(groups[0])
            candidates += ocrCandidates(groups[1])
            candidates += metadataCandidates(groups[2])
            return candidates
        }

        if let spokenPattern {
            let groups = try store.textSearch(
                pattern: spokenPattern, groups: [[.transcript]],
                limitPerGroup: options.channelDepth)
            candidates += transcriptCandidates(groups[0])
        }
        if let literalPattern {
            let groups = try store.textSearch(
                pattern: literalPattern, groups: [Self.ocrKinds, Self.metadataKinds],
                limitPerGroup: options.channelDepth)
            candidates += ocrCandidates(groups[0])
            candidates += metadataCandidates(groups[1])
        }
        return candidates
    }

    private func transcriptCandidates(_ hits: [IndexStore.TextHit]) -> [Candidate] {
        hits.map { hit in
            Candidate(assetID: hit.assetID, momentID: nil,
                      seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                      channel: .transcript, rawScore: hit.score,
                      evidence: .transcript(text: hit.text, seconds: hit.startSeconds))
        }
    }

    private func ocrCandidates(_ hits: [IndexStore.TextHit]) -> [Candidate] {
        hits.map { hit in
            Candidate(assetID: hit.assetID, momentID: hit.momentID,
                      seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                      channel: .ocr, rawScore: hit.score,
                      evidence: .onScreenText(text: hit.text))
        }
    }

    private func metadataCandidates(_ hits: [IndexStore.TextHit]) -> [Candidate] {
        hits.map { hit in
            Candidate(assetID: hit.assetID, momentID: nil,
                      seconds: 0, endSeconds: 0,
                      channel: .metadata, rawScore: hit.score,
                      evidence: .metadata(text: hit.text, kind: hit.kind))
        }
    }

    /// Decides, per term, whether a prefix wildcard is affordable.
    ///
    /// The wildcard exists so a half-typed "presupuest" still finds
    /// "presupuesto", which is worth real money in an incremental search box.
    /// What it must not do is quietly turn one word into a third of the library:
    /// measured on a 1.5 M-row index, `"man"*` matched 516,849 rows because
    /// Spanish is full of words like *manera*, and ranking them took 490 ms —
    /// per channel, three times over.
    ///
    /// So the wildcard is kept wherever it is cheap and dropped where it is not,
    /// using FTS5's own term dictionary to tell the difference. That is a
    /// measurement, not a guess about word length: the same three letters are
    /// harmless in one library and ruinous in another, and only the vocabulary
    /// knows which.
    struct PrefixBudget {
        let store: IndexStore

        /// How many documents a prefix may reach before the wildcard is dropped.
        ///
        /// Derived from measurement rather than taste. Ranking matched rows
        /// costs about a microsecond each on this hardware — 62 K rows took
        /// 50 ms, 517 K took 490 ms — so this is a latency budget written in the
        /// only unit the index can check in advance. It deliberately does not
        /// scale with library size: a prefix that reaches 500 K documents is not
        /// completing anybody's spelling, whether the library holds a million
        /// rows or fifty.
        static let maximumDocuments = 50_000

        func allowsWildcard(after term: String) -> Bool {
            // A failed lookup must not silently narrow the search. Keeping the
            // wildcard is the behaviour this guard is an optimisation of.
            guard let breadth = try? store.prefixBreadth(term.lowercased()) else { return true }
            return breadth <= Self.maximumDocuments
        }
    }

    /// Builds a valid FTS5 MATCH expression. Multi-word terms become quoted
    /// phrases; single words get a prefix wildcard when the index says it is
    /// affordable.
    static func ftsPattern(for terms: [String], budget: PrefixBudget? = nil) -> String? {
        let pieces = terms.compactMap { term -> String? in
            let cleaned = term
                .replacingOccurrences(of: "\"", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2 else { return nil }
            if cleaned.contains(" ") { return "\"\(cleaned)\"" }
            let wildcard = budget?.allowsWildcard(after: cleaned) ?? true
            return wildcard ? "\"\(cleaned)\"*" : "\"\(cleaned)\""
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " OR ")
    }

    // MARK: - Fusion

    private struct FusedCandidate {
        var assetID: Int64
        var momentID: Int64?
        var start: Double
        var end: Double
        var channelScores: [Channel: Double] = [:]
        var evidence: [Evidence] = []
    }

    private func fuse(_ candidates: [Candidate]) -> [FusedCandidate] {
        guard !candidates.isEmpty else { return [] }

        // Normalise each channel to 0…1 on its own scale. bm25 and cosine
        // similarity are not comparable numbers; their *rankings* are.
        var bounds: [Channel: (min: Double, max: Double)] = [:]
        for candidate in candidates {
            let current = bounds[candidate.channel] ?? (candidate.rawScore, candidate.rawScore)
            bounds[candidate.channel] = (min(current.min, candidate.rawScore),
                                         max(current.max, candidate.rawScore))
        }

        func normalize(_ candidate: Candidate) -> Double {
            // Visual scores are already absolute and comparable across queries,
            // so they get calibrated rather than rank-normalised. Text channels
            // use bm25, whose raw value means nothing on its own — only its
            // ordering within this result set does.
            if candidate.channel == .visual {
                let floor = Double(visualFloor)
                let ceiling = Double(visualCeiling)
                return min(1, max(0, (candidate.rawScore - floor) / max(ceiling - floor, 1e-6)))
            }
            guard let range = bounds[candidate.channel] else { return 0 }
            let span = range.max - range.min
            guard span > 1e-9 else { return 1 }
            return (candidate.rawScore - range.min) / span
        }

        // Metadata hits have no meaningful instant — a filename matches the whole
        // file — so they are applied to every moment of the asset rather than
        // arbitrarily latching onto the first one.
        var timeless: [Int64: (score: Double, evidence: Evidence)] = [:]
        var timed: [Int64: [Candidate]] = [:]
        for candidate in candidates {
            if candidate.channel == .metadata {
                let score = normalize(candidate)
                if score > (timeless[candidate.assetID]?.score ?? -1) {
                    timeless[candidate.assetID] = (score, candidate.evidence)
                }
            } else {
                timed[candidate.assetID, default: []].append(candidate)
            }
        }

        var fused: [FusedCandidate] = []
        for (assetID, group) in timed {
            var buckets: [FusedCandidate] = []
            for candidate in group.sorted(by: { $0.seconds < $1.seconds }) {
                // Two hits merge only when they are *different kinds of evidence*
                // landing at nearly the same instant. Two visual hits 25 seconds
                // apart are two different moments of the same interview, not one
                // stronger moment — collapsing them would hide results and
                // manufacture confidence that isn't there.
                let match = buckets.firstIndex { bucket in
                    bucket.channelScores[candidate.channel] == nil
                        && abs(bucket.start - candidate.seconds) <= options.weights.temporalWindow
                }
                if let index = match {
                    buckets[index].channelScores[candidate.channel] = normalize(candidate)
                    buckets[index].evidence.append(candidate.evidence)
                    buckets[index].start = min(buckets[index].start, candidate.seconds)
                    buckets[index].end = max(buckets[index].end, candidate.endSeconds)
                    if buckets[index].momentID == nil { buckets[index].momentID = candidate.momentID }
                } else {
                    var bucket = FusedCandidate(
                        assetID: assetID, momentID: candidate.momentID,
                        start: candidate.seconds, end: candidate.endSeconds)
                    bucket.channelScores[candidate.channel] = normalize(candidate)
                    bucket.evidence.append(candidate.evidence)
                    buckets.append(bucket)
                }
            }
            if let meta = timeless[assetID] {
                for index in buckets.indices {
                    buckets[index].channelScores[.metadata] = meta.score
                    buckets[index].evidence.append(meta.evidence)
                }
            }
            fused += buckets
        }

        // An asset matched only by its name still deserves to show up.
        for (assetID, meta) in timeless where timed[assetID] == nil {
            var bucket = FusedCandidate(assetID: assetID, momentID: nil, start: 0, end: 0)
            bucket.channelScores[.metadata] = meta.score
            bucket.evidence.append(meta.evidence)
            fused.append(bucket)
        }

        return fused
    }

    private func score(_ candidate: FusedCandidate) -> Double {
        let weights = options.weights
        var total = 0.0
        total += weights.visual * (candidate.channelScores[.visual] ?? 0)
        total += weights.transcript * (candidate.channelScores[.transcript] ?? 0)
        total += weights.onScreenText * (candidate.channelScores[.ocr] ?? 0)
        total += weights.metadata * (candidate.channelScores[.metadata] ?? 0)

        // Corroboration bonus, scaled by how strong the agreeing signals are, so
        // two weak matches don't outrank one excellent one.
        let agreeing = candidate.channelScores.filter { $0.value > 0.15 }
        if agreeing.count >= 2 {
            let mean = agreeing.values.reduce(0, +) / Double(agreeing.count)
            total += weights.agreementBonus * mean * Double(agreeing.count - 1)
        }
        return total
    }

    // MARK: - Result assembly

    private func build(results fused: [FusedCandidate]) throws -> [SearchResult] {
        let scored = fused
            .map { (candidate: $0, score: score($0)) }
            .sorted { $0.score > $1.score }

        var top = Array(scored.prefix(options.limit * 3))
        if options.suppressNearDuplicates {
            top = suppressDuplicates(top)
        }
        top = Array(top.prefix(options.limit))

        // Deliberately *not* rescaled so the best hit reads 100%. A weak match
        // should look weak, even when it is the best thing in the library.
        let ceiling = options.weights.visual + options.weights.transcript
            + options.weights.onScreenText + options.weights.metadata

        // Applied against the number a person will actually read, after the same
        // division the result carries — otherwise the threshold would mean
        // something different from what the interface displays.
        if options.minimumConfidence > 0 {
            top = top.filter { min(1, $0.score / ceiling) >= options.minimumConfidence }
        }

        let assetIDs = Array(Set(top.map(\.candidate.assetID)))
        let assets = try store.assets(ids: assetIDs)
        let locationsByAsset = try store.locations(assetIDs: assetIDs)

        // Hydration used to be the quiet N+1 in this method: up to three preview
        // queries per card and one volume lookup per location, so thirty results
        // could issue a hundred round trips before anything reached the screen.
        // The answers are the same; they are now fetched in three.
        let volumeUUIDs = Array(Set(locationsByAsset.values.flatMap { $0 }.map(\.volumeUUID)))
        let volumeRecords = (try? store.volumes(uuids: volumeUUIDs)) ?? [:]

        let exactMomentIDs = top.compactMap(\.candidate.momentID)
        let exactPreviews = (try? store.previewPaths(momentIDs: exactMomentIDs)) ?? [:]
        // Only the cards that did not already resolve a preview need the
        // nearest-frame fallback. Keep one target per card: several results can
        // belong to the same asset but point at different moments.
        var fallbackTargets: [(assetID: Int64, seconds: Double)] = []
        var fallbackTargetByCard: [Int: Int] = [:]
        for (cardIndex, entry) in top.enumerated() {
            if let momentID = entry.candidate.momentID,
               let path = exactPreviews[momentID],
               FileManager.default.fileExists(atPath: path) { continue }
            fallbackTargetByCard[cardIndex] = fallbackTargets.count
            fallbackTargets.append((entry.candidate.assetID, entry.candidate.start))
        }
        let nearestPreviews = fallbackTargets.isEmpty
            ? [:]
            : (try? store.nearestPreviewPaths(targets: fallbackTargets)) ?? [:]

        func previewURL(cardIndex: Int, momentID: Int64?) -> URL? {
            if let momentID, let path = exactPreviews[momentID],
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            guard let requestID = fallbackTargetByCard[cardIndex],
                  let path = nearestPreviews[requestID],
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        return top.enumerated().compactMap { cardIndex, entry -> SearchResult? in
            guard let asset = assets[entry.candidate.assetID] else { return nil }

            // Evidence means "this signal matched the query". Nearby dialogue
            // can be useful context, but presenting it here as evidence made a
            // visual-only hit look like a multimodal agreement. Keep this list
            // truthful; transcript evidence is added only by the transcript
            // search channel.
            let evidence = entry.candidate.evidence

            let locations = (locationsByAsset[entry.candidate.assetID] ?? []).map { location in
                ResolvedLocation(
                    volumeName: volumeRecords[location.volumeUUID]?.name ?? "Unknown volume",
                    volumeUUID: location.volumeUUID,
                    relativePath: location.relativePath,
                    availability: location.availability,
                    url: location.availability == .online
                        ? volumes.absoluteURL(volumeUUID: location.volumeUUID,
                                              relativePath: location.relativePath)
                        : nil)
            }

            let previewPath = previewURL(cardIndex: cardIndex,
                                         momentID: entry.candidate.momentID)

            return SearchResult(
                assetID: entry.candidate.assetID,
                momentID: entry.candidate.momentID,
                displayName: asset.displayName,
                mediaType: asset.mediaType,
                startSeconds: entry.candidate.start,
                endSeconds: max(entry.candidate.end, entry.candidate.start),
                score: min(1, entry.score / ceiling),
                evidence: evidence,
                locations: locations,
                previewPath: previewPath,
                createdAt: asset.createdAt,
                durationSeconds: asset.durationSeconds)
        }
    }

    /// Twelve near-identical frames from the same interview is a worse answer
    /// than three different interviews.
    private func suppressDuplicates(_ entries: [(candidate: FusedCandidate, score: Double)])
        -> [(candidate: FusedCandidate, score: Double)] {
        var perAsset: [Int64: Int] = [:]
        return entries.filter { entry in
            let count = perAsset[entry.candidate.assetID, default: 0]
            guard count < 3 else { return false }
            perAsset[entry.candidate.assetID] = count + 1
            return true
        }
    }
}
