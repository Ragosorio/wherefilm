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
    case sceneLabel(text: String)
    case metadata(text: String, kind: SearchTextKind)

    public var label: String {
        switch self {
        case .visual(let similarity, let phrase):
            "visual · \"\(phrase)\" · cos \(String(format: "%.3f", similarity))"
        case .transcript(let text, let seconds):
            "dialogue · \(SearchResult.timecode(seconds)) · \"\(text.prefix(90))\""
        case .onScreenText(let text): "on-screen text · \"\(text.prefix(60))\""
        case .sceneLabel(let text): "recognised · \(text)"
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
        // MARK: Ordering — weighted reciprocal rank fusion
        //
        // These are RRF weights now, not score multipliers. The previous scheme
        // normalised each channel min-to-max *inside one result set*, which had
        // a defect that is obvious once written down: a channel holding a single
        // candidate has no spread, so that candidate scored 1.0 — a perfect mark
        // for being the only thing there. One stray OCR line could outrank a
        // genuine visual match.
        //
        // Rank fusion has no such failure mode, needs no comparability between
        // bm25 and cosine, and is one line: sum w/(k+rank) over the channels a
        // result appears in. Cormack, Clarke & Büttcher, SIGIR 2009.
        public var visual = 0.45
        public var transcript = 0.35
        public var onScreenText = 0.12
        /// Scene and object labels. Weighted between on-screen text and the
        /// visual channel because that is what it is: a second, independent
        /// opinion about what the frame shows, from a model that is better at
        /// concrete nouns and much worse at everything else.
        public var sceneLabel = 0.2
        public var metadata = 0.08
        /// RRF's damping constant. 60 is the value from the original paper and
        /// the industry default; smaller values make the top rank dominate more.
        public var rrfK: Double = 60

        // MARK: Confidence — what the interface is allowed to claim
        //
        // Deliberately a *separate* number from the ordering score. Ordering
        // asks "which of these is best?"; confidence asks "is any of this any
        // good?", and answering the second with the first is what produced a
        // calibration table where the 80–89% bucket was right a third of the
        // time.
        //
        // Channels combine as a noisy-OR: 1 − ∏(1 − trust·confidence). Two
        // independent signals agreeing raise it, nothing can push it past 1, and
        // the old `agreementBonus` — which was added *outside* the normalising
        // ceiling and so let two mediocre signals display 100% — is gone.
        public var visualTrust = 1.0
        public var transcriptTrust = 0.95
        public var onScreenTextTrust = 0.95
        /// A classifier label is a good signal about a picture and a coarse one:
        /// "dog" is right or wrong, with little in between, but its taxonomy is
        /// far smaller than the things people search for.
        public var sceneLabelTrust = 0.85
        /// How rare a label must be, in this library, to count as evidence.
        public var minimumLabelRarity = 0.35
        /// A filename match says something about the file, not about the frame.
        public var metadataTrust = 0.7
        /// The rank at which a text hit is worth half of a rank-1 hit.
        public var rankHalfLife: Double = 10
        /// Judge a visual hit by how *unusual* it is for this query rather than
        /// by raw cosine.
        ///
        /// A fixed cosine floor assumes every query starts from the same place,
        /// and CLIP's modality gap says otherwise: a query that resembles
        /// nothing in particular can still resemble *everything* slightly, which
        /// is how a landscape library answers "un plato de espagueti" at all.
        public var judgesVisualBySurprise = false
        /// Standard deviations above this query's mean similarity below which a
        /// hit is noise. Only used when `judgesVisualBySurprise` is on.
        public var visualZFloor: Double = 3
        /// Standard deviations at which a hit is as good as it gets.
        public var visualZCeiling: Double = 6
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

    /// How the final list is ordered.
    ///
    /// This is a knob because the right answer was not obvious and had to be
    /// measured — see the table in `docs/`. Rank fusion is the textbook choice
    /// and it is genuinely better at *combining* channels; absolute confidence
    /// is better at *separating* a good answer from a mediocre one, which is
    /// most of what a small, precise library needs.
    public enum Ranking: String, Sendable, CaseIterable {
        /// Weighted reciprocal rank fusion alone.
        case rankFusion
        /// The calibrated noisy-OR confidence alone.
        case confidence
        /// Confidence first, rank fusion as the tiebreaker and nudge.
        case blend
    }

    public struct Options: Sendable {
        public var limit = 20
        public var ranking: Ranking = .confidence
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
        return try build(results: fuse(eligible(text + visual, plan: plan)))
    }

    /// The part of search that never needs Core ML or the vector index.
    public func searchFast(plan: SearchPlan) throws -> [SearchResult] {
        try build(results: fuse(eligible(textCandidates(plan: plan), plan: plan)))
    }

    /// Applies the hard filters the planner has always produced and nobody has
    /// ever read.
    ///
    /// `mediaType` and `dateRange` have been on `SearchPlan` since the first
    /// version and were dropped on the floor: "fotos de la boda" searched video
    /// just as happily, and a date narrowed nothing. They are applied here, at
    /// the last possible moment, because these are the only two parts of a plan
    /// that can *remove* a correct answer rather than merely rank it badly —
    /// which is also why `QueryFilters` only sets them from words that cannot
    /// mean anything else.
    private func eligible(_ candidates: [Candidate], plan: SearchPlan) -> [Candidate] {
        guard plan.mediaType != nil || plan.dateRange != nil, !candidates.isEmpty
        else { return candidates }
        let ids = Array(Set(candidates.map(\.assetID)))
        guard let assets = try? store.assets(ids: ids) else { return candidates }
        return candidates.filter { candidate in
            guard let asset = assets[candidate.assetID] else { return false }
            if let mediaType = plan.mediaType, asset.mediaType != mediaType { return false }
            if let range = plan.dateRange {
                // A file with no known date is not evidence against itself; it is
                // simply not eligible for a question about dates.
                guard let created = asset.createdAt, range.contains(created) else { return false }
            }
            return true
        }
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
                    let text = eligible(try textCandidates(plan: plan), plan: plan)
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

                    let visual = eligible(
                        try await visualCandidates(
                            plan: plan, vectorIndex: vectorIndex, timings: &timings),
                        plan: plan)
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
        /// Position within its own channel, 1-based. This is what fusion orders
        /// by; the raw score is kept only for explanation.
        var rank: Int
        var rawScore: Double
        /// How much this single channel believes its own answer, 0…1, on an
        /// absolute scale that means the same thing for every query.
        var confidence: Double
        var evidence: Evidence
    }

    private enum Channel: Hashable {
        case visual, transcript, ocr, label, metadata
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

        // What this query looks like against the whole library, if the
        // distribution-aware floor is on.
        let profile = options.weights.judgesVisualBySurprise
            ? await LibraryProfile.shared.statistics(
                store: store, modelID: options.variant.modelID, query: query)
            : nil

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

        // What counts as a good visual match, and why it is a z-score.
        //
        // Cosine is absolute for a given model, which is why the first version
        // used a fixed floor of 0.14 — and that was right about the principle
        // and wrong about the statistic. A query's similarities to a library
        // have their own centre and their own spread, and "0.19" means something
        // completely different in each. Measured here: "cirugía en un quirófano"
        // reached cos 0.207 against a frame of rendered text, comfortably above
        // a floor tuned so that real answers survive.
        //
        // Surprise is the right unit: how many standard deviations above this
        // query's own average similarity a hit sits. A real query has a tail; a
        // nonsense query has a bump exactly where its average is.
        //
        // Only the query side is normalised, and that is a measurement, not an
        // oversight.
        //
        // The mirror problem is real: some moments resemble every query. On this
        // fixture a frame of rendered text answered "cirugía en un quirófano" at
        // cos 0.207 and "un plato de espagueti" at 0.187 — CLIP is famously
        // drawn to pictures of writing, and an archive of slates and documents
        // is full of such magnets. The textbook answer is to centre both sides,
        // `cos(q,v) − q·c − v·c + c·c`, so a moment close to everything loses
        // the advantage it gets for free.
        //
        // It was implemented, measured, and thrown away. Over 50 positive cases:
        //
        //     query-centred only   Recall@10 87%   MRR 0.855   nDCG 0.839
        //     both sides centred   Recall@10 83%   MRR 0.412   nDCG 0.535
        //
        // Subtracting a moment's own baseline does not only demote the magnets;
        // it *promotes* whatever sits furthest from the library's centre, which
        // in a library of landscapes is the abstract wallpaper nobody asked for.
        // The correction is symmetric and the problem is not.

        /// Where a hit sits on whichever scale is in force: standard deviations
        /// above this query's mean, or raw cosine when there is no profile.
        func surprise(_ hit: VectorIndex.Hit) -> Double {
            profile.map { $0.zScore(hit.similarity) } ?? Double(hit.similarity)
        }
        let entryFloor = profile == nil ? Double(visualFloor) : options.weights.visualZFloor
        let entryCeiling = profile == nil ? Double(visualCeiling) : options.weights.visualZCeiling

        let usable = hits.filter { surprise($0) >= entryFloor }
        let moments = try store.moments(ids: usable.map(\.momentID))
        timings.record("moments", since: mark)
        // Every phrase, not just the first. The vector actually searched with is
        // the *average* of the ensemble, so naming one phrase as the reason was
        // a small lie in the one place the product promises not to tell them.
        let phrase = plan.visualPhrases.isEmpty
            ? plan.rawQuery
            : plan.visualPhrases.joined(separator: " / ")
        return usable.enumerated().compactMap { position, hit in
            guard let moment = moments[hit.momentID] else { return nil }
            // Cosine is already an absolute scale for a given model, so the
            // channel's own confidence needs no result set to be computed
            // against — which is exactly why it survives a query that matched
            // nothing well.
            let calibrated = (surprise(hit) - entryFloor) / max(entryCeiling - entryFloor, 1e-6)
            return Candidate(
                assetID: moment.assetID, momentID: hit.momentID,
                seconds: moment.startSeconds, endSeconds: moment.endSeconds,
                channel: .visual, rank: position + 1, rawScore: Double(hit.similarity),
                confidence: min(1, max(0, calibrated)),
                evidence: .visual(similarity: hit.similarity, phrase: phrase))
        }
    }

    private static let ocrKinds: [SearchTextKind] = [.ocr]
    private static let labelKinds: [SearchTextKind] = [.label]
    private static let metadataKinds: [SearchTextKind] = [.filename, .folder, .metadata, .note]

    /// Words that carry no meaning in a label lookup.
    ///
    /// The visual phrases are English by the time they reach here, and several
    /// of them are caption templates this planner added itself — searching the
    /// label index for "photo" would match nothing useful and cost a scan.
    static let labelStopWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "with", "and", "or",
        "photo", "picture", "image", "video", "frame", "shot", "scene", "view",
    ]

    /// The FTS pattern for the label channel, built from the English half of the
    /// query rather than from the words the person typed.
    ///
    /// This is the point of the channel. Vision's taxonomy is English
    /// (`duck`, `printed_page`), the transcript is Spanish, and the same query
    /// has to reach both. The translation the visual channel already needed is
    /// what makes "un pato amarillo" find a label that says "duck".
    static func labelPattern(for phrases: [String], budget: PrefixBudget? = nil) -> String? {
        var seen = Set<String>()
        let words = phrases
            .flatMap { Lexicon.fold($0).split(separator: " ").map(String.init) }
            .filter { $0.count > 2 && !labelStopWords.contains($0) }
            .filter { seen.insert($0).inserted }
        return ftsPattern(for: words, budget: budget)
    }

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
        // Labels are matched against the *English* half of the query, because
        // Vision's taxonomy is English and the person's words usually are not.
        let labelPattern = Self.labelPattern(for: plan.visualPhrases, budget: breadth)
        if let labelPattern {
            let groups = try store.textSearch(
                pattern: labelPattern, groups: [Self.labelKinds],
                limitPerGroup: options.channelDepth)
            candidates += labelCandidates(groups[0], phrases: plan.visualPhrases)
        }

        if let literalPattern, literalPattern == spokenPattern {
            let groups = try store.textSearch(
                pattern: literalPattern,
                groups: [[.transcript], Self.ocrKinds, Self.metadataKinds],
                limitPerGroup: options.channelDepth)
            candidates += transcriptCandidates(groups[0], terms: plan.spokenTerms)
            candidates += ocrCandidates(groups[1], terms: plan.literalTerms)
            candidates += metadataCandidates(groups[2], terms: plan.literalTerms)
            return candidates
        }

        if let spokenPattern {
            let groups = try store.textSearch(
                pattern: spokenPattern, groups: [[.transcript]],
                limitPerGroup: options.channelDepth)
            candidates += transcriptCandidates(groups[0], terms: plan.spokenTerms)
        }
        if let literalPattern {
            let groups = try store.textSearch(
                pattern: literalPattern, groups: [Self.ocrKinds, Self.metadataKinds],
                limitPerGroup: options.channelDepth)
            candidates += ocrCandidates(groups[0], terms: plan.literalTerms)
            candidates += metadataCandidates(groups[1], terms: plan.literalTerms)
        }
        return candidates
    }

    private func transcriptCandidates(_ hits: [IndexStore.TextHit], terms: [String]) -> [Candidate] {
        hits.enumerated().map { position, hit in
            Candidate(assetID: hit.assetID, momentID: nil,
                      seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                      channel: .transcript, rank: position + 1, rawScore: hit.score,
                      confidence: Self.textConfidence(hit: hit, position: position, terms: terms,
                                                      halfLife: options.weights.rankHalfLife),
                      evidence: .transcript(text: hit.text, seconds: hit.startSeconds))
        }
    }

    private func ocrCandidates(_ hits: [IndexStore.TextHit], terms: [String]) -> [Candidate] {
        hits.enumerated().map { position, hit in
            Candidate(assetID: hit.assetID, momentID: hit.momentID,
                      seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                      channel: .ocr, rank: position + 1, rawScore: hit.score,
                      confidence: Self.textConfidence(hit: hit, position: position, terms: terms,
                                                      halfLife: options.weights.rankHalfLife),
                      evidence: .onScreenText(text: hit.text))
        }
    }

    private func labelCandidates(_ hits: [IndexStore.TextHit], phrases: [String]) -> [Candidate] {
        // Coverage is measured the other way round here. A label is one or two
        // words and the query is a sentence, so asking "how much of the query is
        // in this label" would score every label near zero. The useful question
        // is whether the label's own words appear in what was asked for.
        let haystack = phrases.map { Lexicon.fold($0) }.joined(separator: " ")

        // How much each matched label is worth *in this library*.
        let identifiers = Array(Set(hits.map { $0.text.replacingOccurrences(of: " ", with: "_") }))
        let frequencies = (try? store.labelFrequencies(identifiers: identifiers)) ?? ([:], 0)

        return hits.enumerated().compactMap { position, hit in
            let words = Lexicon.fold(hit.text).split(separator: " ").map(String.init)
            let matched = words.filter { haystack.contains($0) }.count
            guard matched > 0 else { return nil }
            let coverage = Double(matched) / Double(max(words.count, 1))
            let decay = 1 / (1 + Double(position) / max(options.weights.rankHalfLife, 1))
            let identifier = hit.text.replacingOccurrences(of: " ", with: "_")
            let rarity = Self.rarity(of: identifier, in: frequencies)
            // A label the whole library shares is not evidence about any of it.
            // Admitted at all, `sky` in a library of landscapes promotes thirty
            // files equally and buries the one that matched on something real.
            guard rarity >= options.weights.minimumLabelRarity else { return nil }
            return Candidate(assetID: hit.assetID, momentID: hit.momentID,
                             seconds: hit.startSeconds, endSeconds: hit.endSeconds,
                             channel: .label, rank: position + 1, rawScore: hit.score,
                             confidence: coverage * decay * rarity,
                             evidence: .sceneLabel(text: hit.text))
        }
    }

    /// Inverse document frequency, normalised to 0…1.
    ///
    /// A label on nearly every asset scores near zero and a label on a handful
    /// scores near one, which is exactly the judgement bm25 makes for words and
    /// this channel has to make for itself: the label index is queried by the
    /// query's *English* half, so its ranking cannot borrow the text index's.
    static func rarity(of identifier: String,
                       in frequencies: (counts: [String: Int], assets: Int)) -> Double {
        let total = frequencies.assets
        guard total > 1 else { return 1 }
        let count = max(1, frequencies.counts[identifier] ?? 1)
        guard count < total else { return 0 }
        return log(Double(total) / Double(count)) / log(Double(total))
    }

    private func metadataCandidates(_ hits: [IndexStore.TextHit], terms: [String]) -> [Candidate] {
        hits.enumerated().map { position, hit in
            Candidate(assetID: hit.assetID, momentID: nil,
                      seconds: 0, endSeconds: 0,
                      channel: .metadata, rank: position + 1, rawScore: hit.score,
                      confidence: Self.textConfidence(hit: hit, position: position, terms: terms,
                                                      halfLife: options.weights.rankHalfLife),
                      evidence: .metadata(text: hit.text, kind: hit.kind))
        }
    }

    /// How much a text channel should believe its own hit.
    ///
    /// bm25 is not an absolute scale — its value depends on the corpus, so the
    /// only thing it supports is ordering. Two things about a hit *are*
    /// absolute, though, and together they are enough:
    ///
    ///   **coverage** — how many of the query's words this text actually
    ///   contains. The MATCH expression is an OR, so one word out of six is a
    ///   legitimate match and a poor answer. This is what stops "numero de
    ///   factura 99999" from confidently returning whatever contained *numero*.
    ///
    ///   **rank decay** — being the fiftieth-best match for a word is weaker
    ///   evidence than being the first.
    static func textConfidence(hit: IndexStore.TextHit, position: Int,
                               terms: [String], halfLife: Double) -> Double {
        let decay = 1 / (1 + Double(position) / max(halfLife, 1))
        return termCoverage(text: hit.text, terms: terms) * decay
    }

    /// The fraction of the query's terms this text really contains.
    ///
    /// Folded on both sides, so accents and case cannot cause a false miss, and
    /// prefix-tolerant by construction: the FTS pattern searches `presupuest*`,
    /// and the stored word contains that prefix.
    static func termCoverage(text: String, terms: [String]) -> Double {
        let usable = terms.filter { $0.count >= 2 }
        guard !usable.isEmpty else { return 1 }
        let haystack = Lexicon.fold(text)
        let matched = usable.filter { haystack.contains(Lexicon.fold($0)) }.count
        return Double(matched) / Double(usable.count)
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
        /// Best (lowest) rank this result reached in each channel.
        var channelRanks: [Channel: Int] = [:]
        /// Each channel's own absolute belief in this result.
        var channelConfidence: [Channel: Double] = [:]
        var evidence: [Evidence] = []
    }

    private func fuse(_ candidates: [Candidate]) -> [FusedCandidate] {
        guard !candidates.isEmpty else { return [] }

        // Metadata hits have no meaningful instant — a filename matches the whole
        // file — so they are applied to every moment of the asset rather than
        // arbitrarily latching onto the first one.
        var timeless: [Int64: Candidate] = [:]
        var timed: [Int64: [Candidate]] = [:]
        for candidate in candidates {
            if candidate.channel == .metadata {
                if candidate.rank < (timeless[candidate.assetID]?.rank ?? Int.max) {
                    timeless[candidate.assetID] = candidate
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
                    bucket.channelRanks[candidate.channel] == nil
                        && abs(bucket.start - candidate.seconds) <= options.weights.temporalWindow
                }
                if let index = match {
                    buckets[index].channelRanks[candidate.channel] = candidate.rank
                    buckets[index].channelConfidence[candidate.channel] = candidate.confidence
                    buckets[index].evidence.append(candidate.evidence)
                    buckets[index].start = min(buckets[index].start, candidate.seconds)
                    buckets[index].end = max(buckets[index].end, candidate.endSeconds)
                    if buckets[index].momentID == nil { buckets[index].momentID = candidate.momentID }
                } else {
                    var bucket = FusedCandidate(
                        assetID: assetID, momentID: candidate.momentID,
                        start: candidate.seconds, end: candidate.endSeconds)
                    bucket.channelRanks[candidate.channel] = candidate.rank
                    bucket.channelConfidence[candidate.channel] = candidate.confidence
                    bucket.evidence.append(candidate.evidence)
                    buckets.append(bucket)
                }
            }
            if let meta = timeless[assetID] {
                for index in buckets.indices {
                    buckets[index].channelRanks[.metadata] = meta.rank
                    buckets[index].channelConfidence[.metadata] = meta.confidence
                    buckets[index].evidence.append(meta.evidence)
                }
            }
            fused += buckets
        }

        // An asset matched only by its name still deserves to show up.
        for (assetID, meta) in timeless where timed[assetID] == nil {
            var bucket = FusedCandidate(assetID: assetID, momentID: nil, start: 0, end: 0)
            bucket.channelRanks[.metadata] = meta.rank
            bucket.channelConfidence[.metadata] = meta.confidence
            bucket.evidence.append(meta.evidence)
            fused.append(bucket)
        }

        return fused
    }

    private func weight(_ channel: Channel) -> Double {
        switch channel {
        case .visual: options.weights.visual
        case .transcript: options.weights.transcript
        case .ocr: options.weights.onScreenText
        case .label: options.weights.sceneLabel
        case .metadata: options.weights.metadata
        }
    }

    private func trust(_ channel: Channel) -> Double {
        switch channel {
        case .visual: options.weights.visualTrust
        case .transcript: options.weights.transcriptTrust
        case .ocr: options.weights.onScreenTextTrust
        case .label: options.weights.sceneLabelTrust
        case .metadata: options.weights.metadataTrust
        }
    }

    /// What orders the list: weighted reciprocal rank fusion.
    ///
    /// Position, not magnitude. A result that is third in the visual channel and
    /// second in the transcript beats one that is first in a single channel, and
    /// none of it requires bm25 and cosine to be the same kind of number.
    private func rankScore(_ candidate: FusedCandidate) -> Double {
        candidate.channelRanks.reduce(0.0) { total, entry in
            total + weight(entry.key) / (options.weights.rrfK + Double(entry.value))
        }
    }

    /// The number the list is sorted by.
    ///
    /// `blend` multiplies the two: rank fusion decides *relative* order within a
    /// band of similar quality, and confidence decides which band a result is in
    /// at all. Multiplying rather than adding means a result no channel believes
    /// cannot climb by appearing in many channels weakly — which was exactly how
    /// "un plato de espagueti" collected four answers.
    private func ordering(_ candidate: FusedCandidate) -> Double {
        switch options.ranking {
        case .rankFusion: rankScore(candidate)
        case .confidence: confidence(candidate)
        case .blend: rankScore(candidate) * (0.25 + 0.75 * confidence(candidate))
        }
    }

    /// What the interface may claim: noisy-OR over the channels' own beliefs.
    ///
    /// Independent evidence compounds — 0.6 and 0.6 make 0.84, which is the
    /// product's whole thesis in one line — while nothing can exceed 1, so no
    /// arrangement of weak signals can ever display as certainty.
    private func confidence(_ candidate: FusedCandidate) -> Double {
        let miss = candidate.channelConfidence.reduce(1.0) { product, entry in
            product * (1 - trust(entry.key) * min(1, max(0, entry.value)))
        }
        return 1 - miss
    }

    // MARK: - Result assembly

    private func build(results fused: [FusedCandidate]) throws -> [SearchResult] {
        // Ordered by rank fusion, reported by confidence. Ties in RRF are common
        // and meaningful — two results at the same rank in the same channel —
        // so confidence breaks them, which keeps the order stable and puts the
        // better-evidenced of two equals first.
        let scored = fused
            .map { (candidate: $0, score: ordering($0), confidence: confidence($0)) }
            .sorted {
                $0.score == $1.score ? $0.confidence > $1.confidence : $0.score > $1.score
            }

        var top = Array(scored.prefix(options.limit * 3))
        if options.suppressNearDuplicates {
            top = suppressDuplicates(top)
        }
        top = Array(top.prefix(options.limit))

        // Deliberately *not* rescaled so the best hit reads 100%. A weak match
        // should look weak, even when it is the best thing in the library.
        if options.minimumConfidence > 0 {
            top = top.filter { $0.confidence >= options.minimumConfidence }
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
                score: entry.confidence,
                evidence: evidence,
                locations: locations,
                previewPath: previewPath,
                createdAt: asset.createdAt,
                durationSeconds: asset.durationSeconds)
        }
    }

    /// Twelve near-identical frames from the same interview is a worse answer
    /// than three different interviews.
    private func suppressDuplicates(
        _ entries: [(candidate: FusedCandidate, score: Double, confidence: Double)]
    ) -> [(candidate: FusedCandidate, score: Double, confidence: Double)] {
        var perAsset: [Int64: Int] = [:]
        return entries.filter { entry in
            let count = perAsset[entry.candidate.assetID, default: 0]
            guard count < 3 else { return false }
            perAsset[entry.candidate.assetID] = count + 1
            return true
        }
    }
}
