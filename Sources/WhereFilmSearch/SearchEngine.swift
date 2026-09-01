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
    public var options: Options

    public init(store: IndexStore, volumes: VolumeRegistry = VolumeRegistry(),
                options: Options = Options()) {
        self.store = store
        self.volumes = volumes
        self.options = options
    }

    var visualFloor: Float {
        options.weights.minimumVisualSimilarity ?? options.variant.similarityFloor
    }

    var visualCeiling: Float {
        options.weights.strongVisualSimilarity ?? options.variant.similarityCeiling
    }

    public func search(plan: SearchPlan, vectorIndex: VectorIndex?) async throws -> [SearchResult] {
        var candidates: [Candidate] = []

        candidates += try await visualCandidates(plan: plan, vectorIndex: vectorIndex)
        candidates += try textCandidates(plan: plan)

        let merged = fuse(candidates)
        return try build(results: merged)
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
        guard plan.hasVisualSignal else { return [] }

        let encoder: MobileCLIPTextEncoder
        do {
            encoder = try MobileCLIPTextEncoder(variant: options.variant)
        } catch {
            // No visual model installed yet: text search still works. Degrading
            // is better than failing.
            return []
        }

        let query = try encoder.encodeEnsemble(plan.visualPhrases)
        guard !query.isEmpty else { return [] }

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

        let usable = hits.filter { $0.similarity >= visualFloor }
        let moments = try store.moments(ids: usable.map(\.momentID))
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

    private func textCandidates(plan: SearchPlan) throws -> [Candidate] {
        var candidates: [Candidate] = []

        if !plan.spokenTerms.isEmpty,
           let pattern = Self.ftsPattern(for: plan.spokenTerms) {
            for hit in try store.textSearch(pattern: pattern, kinds: [.transcript],
                                            limit: options.channelDepth) {
                candidates.append(Candidate(
                    assetID: hit.assetID, momentID: nil,
                    seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                    channel: .transcript, rawScore: hit.score,
                    evidence: .transcript(text: hit.text, seconds: hit.startSeconds)))
            }
        }

        if !plan.literalTerms.isEmpty,
           let pattern = Self.ftsPattern(for: plan.literalTerms) {
            for hit in try store.textSearch(pattern: pattern, kinds: [.ocr],
                                            limit: options.channelDepth) {
                candidates.append(Candidate(
                    assetID: hit.assetID, momentID: hit.momentID,
                    seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                    channel: .ocr, rawScore: hit.score,
                    evidence: .onScreenText(text: hit.text)))
            }
            for hit in try store.textSearch(pattern: pattern,
                                            kinds: [.filename, .folder, .metadata, .note],
                                            limit: options.channelDepth) {
                candidates.append(Candidate(
                    assetID: hit.assetID, momentID: nil,
                    seconds: 0, endSeconds: 0,
                    channel: .metadata, rawScore: hit.score,
                    evidence: .metadata(text: hit.text, kind: hit.kind)))
            }
        }

        return candidates
    }

    /// Builds a valid FTS5 MATCH expression. Multi-word terms become quoted
    /// phrases; single words get a prefix wildcard so "presupuest" still finds
    /// "presupuesto".
    static func ftsPattern(for terms: [String]) -> String? {
        let pieces = terms.compactMap { term -> String? in
            let cleaned = term
                .replacingOccurrences(of: "\"", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2 else { return nil }
            return cleaned.contains(" ") ? "\"\(cleaned)\"" : "\"\(cleaned)\"*"
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

        return top.compactMap { entry -> SearchResult? in
            guard let asset = assets[entry.candidate.assetID] else { return nil }

            // Evidence means "this signal matched the query". Nearby dialogue
            // can be useful context, but presenting it here as evidence made a
            // visual-only hit look like a multimodal agreement. Keep this list
            // truthful; transcript evidence is added only by the transcript
            // search channel.
            let evidence = entry.candidate.evidence

            let locations = (locationsByAsset[entry.candidate.assetID] ?? []).map { location in
                ResolvedLocation(
                    volumeName: (try? store.volume(uuid: location.volumeUUID))?.name ?? "Unknown volume",
                    volumeUUID: location.volumeUUID,
                    relativePath: location.relativePath,
                    availability: location.availability,
                    url: location.availability == .online
                        ? volumes.absoluteURL(volumeUUID: location.volumeUUID,
                                              relativePath: location.relativePath)
                        : nil)
            }

            var previewPath: URL?
            if let momentID = entry.candidate.momentID {
                previewPath = try? PreviewLookup(store: store).url(momentID: momentID)
            }

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

/// Read-only preview lookup, so the search layer doesn't need to depend on the
/// indexing module just to show a thumbnail.
struct PreviewLookup {
    let store: IndexStore

    func url(momentID: Int64) throws -> URL? {
        let path = try store.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT cachePath FROM previews WHERE momentID = ?",
                                arguments: [momentID])
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
