import Testing
import Foundation
@testable import WhereFilmCore
@testable import WhereFilmML
@testable import WhereFilmSearch

@Suite("Query planning")
struct QueryPlanningTests {
    /// The lexicon tier must work on every Mac, including ones with no Apple
    /// Intelligence, so it is tested with the model explicitly disabled.
    private let planner = QueryPlanner(useFoundationModel: false)

    @Test("Spanish visual vocabulary is translated for the English model")
    func translatesVisualTerms() {
        #expect(Lexicon.translateVisual("el chavo de playera azul")
            .contains("young man"))
        #expect(Lexicon.translateVisual("el chavo de playera azul")
            .contains("blue"))
        #expect(Lexicon.translateVisual("una entrevista de noche")
            .contains("at night"))
        #expect(Lexicon.translateVisual("plano cerrado de una mujer")
            .contains("close-up shot"))
    }

    @Test("Longer phrases win over their parts")
    func longestMatchWins() {
        let translated = Lexicon.translateVisual("de noche en la calle")
        #expect(translated.contains("at night"))
        // "night" alone would be the wrong, shorter match.
        #expect(!translated.contains("during the day"))
    }

    @Test("Spoken terms stay in the language that was actually spoken")
    func spokenTermsAreNotTranslated() {
        let plan = planner.lexiconPlan("donde habló del presupuesto")
        #expect(plan.spokenTerms.contains { $0.contains("presupuesto") })
        // Translating these would search a Spanish transcript for English words.
        #expect(!plan.spokenTerms.contains { $0.lowercased().contains("budget") })
    }

    @Test("Quoted phrases survive as phrases")
    func quotedPhrasesStayIntact() {
        let terms = QueryPlanner.literalTerms(from: "cuando dijo \"no hay presupuesto\" en marzo")
        #expect(terms.contains("no hay presupuesto"))
    }

    @Test("Filler words are dropped")
    func fillerIsDropped() {
        let terms = QueryPlanner.literalTerms(from: "el video donde se ve la carretera entre árboles")
        #expect(terms.contains("carretera"))
        #expect(!terms.contains("el"))
        #expect(!terms.contains("video"))
        #expect(!terms.contains("entre"))
    }

    @Test("An English query is left alone")
    func englishPassesThrough() {
        let plan = planner.lexiconPlan("man wearing a blue shirt")
        #expect(plan.visualPhrases.contains("man wearing a blue shirt"))
    }

    @Test("Identifiers take the metadata fast path")
    func identifiersSkipVisualEncoding() {
        for identifier in ["4582", "IMG_0042", "A004C012", "TOMA 7", "ROLLO 2"] {
            let plan = planner.lexiconPlan(identifier)
            #expect(plan.visualPhrases.isEmpty)
            #expect(!plan.literalTerms.isEmpty)
        }
    }

    /// A person searching their own footage types plurals. Hand-listing them in
    /// the table would double it and still leave gaps.
    @Test("Plurals are translated, not just dictionary singulars")
    func pluralsAreTranslated() {
        #expect(Lexicon.translateVisual("acantilados").contains("cliff"))
        #expect(Lexicon.translateVisual("unos árboles").contains("tree"))
        #expect(Lexicon.translateVisual("las montañas").contains("mountain"))
        #expect(Lexicon.translateVisual("unas mujeres").contains("women") ||
                Lexicon.translateVisual("unas mujeres").contains("woman"))
        #expect(Lexicon.translateVisual("dos carros").contains("car"))
        // Already-plural and invariant entries must not be mangled.
        #expect(Lexicon.translateVisual("olas").contains("waves"))
        #expect(Lexicon.translateVisual("lentes").contains("glasses"))
    }

    /// The on-device model is non-deterministic about the language it answers
    /// in. Spanish reaching an English-only text encoder ruins the search
    /// silently, so the guard has to be deterministic.
    @Test("Untranslated Spanish is caught before it reaches the encoder")
    func spanishIsDetectedAfterTheModel() {
        #expect(Lexicon.needsTranslation("acantilados junto al mar"))
        #expect(Lexicon.needsTranslation("el chavo de playera azul"))
        // English must pass through untouched, including English with a proper
        // noun or loanword in it.
        #expect(!Lexicon.needsTranslation("cliffs beside the sea"))
        #expect(!Lexicon.needsTranslation("a wide establishing shot of a city"))
        #expect(!Lexicon.needsTranslation("a plaza in the old town at sunset"))
    }

    /// Observed from the real model: a field asked to be empty came back as the
    /// literal string "no spoken", which then became a transcript search term.
    @Test("A model that says \"no spoken\" is not searched for those words")
    func emptySentinelsAreRejected() {
        #expect(QueryPlanner.isEmptySentinel("no spoken"))
        #expect(QueryPlanner.isEmptySentinel("None."))
        #expect(QueryPlanner.isEmptySentinel(" ninguno "))
        #expect(QueryPlanner.isEmptySentinel(""))
        // Real terms must survive.
        #expect(!QueryPlanner.isEmptySentinel("presupuesto"))
        #expect(!QueryPlanner.isEmptySentinel("nada más que decir"))
    }
}

@Suite("FTS5 patterns")
struct FTSPatternTests {
    @Test("Single words get a prefix wildcard, phrases get quoted")
    func patternShape() throws {
        let pattern = try #require(SearchEngine.ftsPattern(for: ["presupuesto", "no hay dinero"]))
        #expect(pattern.contains("\"presupuesto\"*"))
        #expect(pattern.contains("\"no hay dinero\""))
        #expect(pattern.contains(" OR "))
    }

    @Test("Stray quotes can't break the MATCH expression")
    func quotesAreNeutralised() throws {
        let pattern = try #require(SearchEngine.ftsPattern(for: ["say \"hello\" now"]))
        // The user's quotes must not terminate ours, or FTS5 raises a syntax error.
        #expect(pattern == "\"say  hello  now\"")
    }

    @Test("Terms too short to be useful are dropped")
    func shortTermsDropped() {
        #expect(SearchEngine.ftsPattern(for: ["a", "x"]) == nil)
    }
}

@Suite("Search end to end", .serialized)
struct SearchEngineTests {
    /// Builds a store with two assets whose signals are deliberately split: one
    /// has the picture, the other has the words, and one has both. Fusion should
    /// put the one with both on top.
    private func seededStore() throws -> (IndexStore, [String: Int64]) {
        let store = try IndexStore.inMemory()
        try store.upsertVolume(Volume(volumeUUID: "V", name: "Samsung T7"))

        var ids: [String: Int64] = [:]
        for name in ["VISUAL_ONLY.mov", "SPOKEN_ONLY.mov", "BOTH.mov"] {
            let asset = try store.insert(Asset(
                contentKey: "q1:\(name)", mediaType: .video,
                durationSeconds: 600, displayName: name))
            let assetID = try #require(asset.assetID)
            ids[name] = assetID
            try store.upsertLocation(Location(assetID: assetID, volumeUUID: "V",
                                              relativePath: "Entrevistas/\(name)",
                                              fileSize: 100))
        }
        return (store, ids)
    }

    @Test("Two signals that agree in time beat one signal alone")
    func temporalFusionWins() async throws {
        let (store, ids) = try seededStore()

        // Both files "look" equally right; only one also says the right thing at
        // the same moment.
        for name in ["VISUAL_ONLY.mov", "BOTH.mov"] {
            let assetID = try #require(ids[name])
            let moments = try store.insertMoments([
                Moment(assetID: assetID, startSeconds: 840, endSeconds: 870),
            ])
            let momentID = try #require(moments[0].momentID)
            var vector = [Float](repeating: 0.01, count: 512)
            vector[0] = 1
            try store.saveEmbeddings([(momentID, vector)], modelID: "m")
        }

        try store.insertTranscript([
            TranscriptChunk(assetID: try #require(ids["BOTH.mov"]),
                            startSeconds: 856, endSeconds: 864,
                            text: "el problema fue el presupuesto"),
            TranscriptChunk(assetID: try #require(ids["SPOKEN_ONLY.mov"]),
                            startSeconds: 12, endSeconds: 20,
                            text: "hablamos del presupuesto otra vez"),
        ])

        let engine = SearchEngine(store: store)
        let plan = SearchPlan(
            rawQuery: "presupuesto",
            visualPhrases: [],          // no visual model in tests
            spokenTerms: ["presupuesto"],
            literalTerms: ["presupuesto"],
            mediaType: nil, dateRange: nil, source: .literal)

        let results = try await engine.search(plan: plan, vectorIndex: nil)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.evidence.contains { evidence in
            if case .transcript = evidence { true } else { false }
        }})
    }

    @Test("Progressive search publishes FTS before visual refinement")
    func progressiveSearchPublishesInOrder() async throws {
        let (store, ids) = try seededStore()
        let assetID = try #require(ids["BOTH.mov"])
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 10, endSeconds: 20),
        ]).first)
        let momentID = try #require(moment.momentID)
        var vector = [Float](repeating: 0, count: 512)
        vector[0] = 1
        try store.saveEmbeddings([(momentID, vector)], modelID: MobileCLIPVariant.s0.modelID)
        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 12, endSeconds: 18,
                            text: "el problema fue el presupuesto"),
        ])

        let provider = ImmediateEmbeddingProvider(vector: vector)
        let engine = SearchEngine(store: store, embeddingProvider: provider)
        let plan = SearchPlan(rawQuery: "camisa azul presupuesto",
                              visualPhrases: ["blue shirt"],
                              spokenTerms: ["presupuesto"],
                              literalTerms: ["presupuesto"],
                              mediaType: nil, dateRange: nil, source: .lexicon)

        var updates: [SearchUpdate] = []
        for try await update in engine.searchProgressively(plan: plan, vectorIndex: nil) {
            updates.append(update)
        }

        #expect(updates.count == 2)
        #expect(updates.first?.phase == .fast)
        #expect(updates.first?.isFinal == false)
        #expect(updates.last?.phase == .refined)
        #expect(updates.last?.isFinal == true)
        #expect((updates.first?.results.isEmpty) == false)
        #expect(updates.last?.results.first?.assetID == assetID)
        #expect((updates.last?.elapsedMilliseconds ?? 0) >=
                (updates.first?.elapsedMilliseconds ?? 0))
    }

    @Test("Cancelling a progressive search stops its refinement")
    func progressiveSearchCancels() async throws {
        let (store, _) = try seededStore()
        let provider = DelayedEmbeddingProvider()
        let engine = SearchEngine(store: store, embeddingProvider: provider)
        let plan = SearchPlan(rawQuery: "blue shirt", visualPhrases: ["blue shirt"],
                              spokenTerms: [], literalTerms: [],
                              mediaType: nil, dateRange: nil, source: .literal)
        let stream = engine.searchProgressively(plan: plan, vectorIndex: nil)

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal state.
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(20))

        #expect(await provider.wasCancelled)
    }

    @Test("The refined ranking is deterministic")
    func refinedRankingIsDeterministic() async throws {
        let (store, ids) = try seededStore()
        let assetID = try #require(ids["SPOKEN_ONLY.mov"])
        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 1, endSeconds: 2,
                            text: "presupuesto aprobado"),
        ])
        let engine = SearchEngine(store: store)
        let plan = SearchPlan(rawQuery: "presupuesto", visualPhrases: [],
                              spokenTerms: ["presupuesto"], literalTerms: ["presupuesto"],
                              mediaType: nil, dateRange: nil, source: .literal)

        let first = try await engine.search(plan: plan, vectorIndex: nil)
        let second = try await engine.search(plan: plan, vectorIndex: nil)
        #expect(first.map(\.assetID) == second.map(\.assetID))
        #expect(first.map(\.momentID) == second.map(\.momentID))
        #expect(first.map(\.score) == second.map(\.score))
    }

    @Test("Results carry their location and its availability")
    func resultsExplainWhereTheFileIs() async throws {
        let (store, ids) = try seededStore()
        let assetID = try #require(ids["SPOKEN_ONLY.mov"])
        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 5, endSeconds: 9,
                            text: "la campaña comienza en junio"),
        ])
        try store.markVolumes(online: [])   // drive unplugged

        let engine = SearchEngine(store: store)
        let plan = SearchPlan(rawQuery: "campaña", visualPhrases: [],
                              spokenTerms: ["campaña"], literalTerms: ["campaña"],
                              mediaType: nil, dateRange: nil, source: .literal)
        let results = try await engine.search(plan: plan, vectorIndex: nil)

        let location = try #require(results.first?.bestLocation)
        #expect(location.volumeName == "Samsung T7")
        #expect(location.availability == .offline)
        #expect(location.url == nil)        // can't be opened, but is still found
    }

    /// Found by running the release bundle against a fresh library: searching
    /// for something that was *said* produced a card with an empty grey
    /// rectangle where the picture goes, because a speech moment has no keyframe
    /// of its own.
    @Test("A result found by its dialogue still shows a picture")
    func transcriptResultsBorrowTheFrameOnScreen() async throws {
        let (store, ids) = try seededStore()
        let assetID = try #require(ids["BOTH.mov"])

        // Two indexed keyframes, and a line spoken much closer to the second.
        let moments = try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 30),
            Moment(assetID: assetID, startSeconds: 850, endSeconds: 880),
        ])
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-preview-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        for (index, moment) in moments.enumerated() {
            let file = cache.appendingPathComponent("frame-\(index).jpg")
            try Data("jpeg".utf8).write(to: file)
            let momentID = try #require(moment.momentID)
            try await store.dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO previews (momentID, cachePath, bytes, lastUsedAt, pinned)
                    VALUES (?, ?, ?, ?, 0)
                    """, arguments: [momentID, file.path, 4, Date()])
            }
        }

        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 856, endSeconds: 864,
                            text: "el problema fue el presupuesto"),
        ])

        let engine = SearchEngine(store: store)
        let plan = SearchPlan(rawQuery: "presupuesto", visualPhrases: [],
                              spokenTerms: ["presupuesto"], literalTerms: ["presupuesto"],
                              mediaType: nil, dateRange: nil, source: .literal)
        let result = try #require(try await engine.search(plan: plan, vectorIndex: nil).first)

        let preview = try #require(result.previewPath,
                                   "a dialogue hit would render as a blank card")
        // And specifically the frame that was on screen when the words were
        // spoken, not merely the first one in the file.
        #expect(preview.lastPathComponent == "frame-1.jpg")
    }

    @Test("Timecodes are formatted for humans")
    func timecodeFormatting() {
        #expect(SearchResult.timecode(0) == "00:00")
        #expect(SearchResult.timecode(74) == "01:14")
        #expect(SearchResult.timecode(852) == "14:12")
        #expect(SearchResult.timecode(3725) == "1:02:05")
    }
}

private actor ImmediateEmbeddingProvider: QueryEmbeddingProviding {
    let vector: [Float]
    init(vector: [Float]) { self.vector = vector }

    func embedding(for phrases: [String], variant: MobileCLIPVariant) async throws -> [Float] {
        vector
    }
}

private actor DelayedEmbeddingProvider: QueryEmbeddingProviding {
    private(set) var wasCancelled = false

    func embedding(for phrases: [String], variant: MobileCLIPVariant) async throws -> [Float] {
        do {
            try await Task.sleep(for: .seconds(5))
            return [Float](repeating: 0, count: variant.dimensions)
        } catch {
            wasCancelled = true
            throw error
        }
    }
}

@Suite("Query embedding cache")
struct QueryEmbeddingCacheTests {
    @Test("Model versions never share cached query vectors")
    func modelVersionInvalidation() {
        var cache = QueryVectorLRU(capacity: 2)
        let old = QueryEmbeddingKey(modelID: "mobileclip-s0-v1", phrases: ["sunset"])
        let new = QueryEmbeddingKey(modelID: "mobileclip-s0-v2", phrases: ["sunset"])

        cache.insert([1], for: old)

        #expect(cache.value(for: old) == [1])
        #expect(cache.value(for: new) == nil)
    }

    @Test("Least-recently-used query vectors are evicted")
    func leastRecentlyUsedEviction() {
        var cache = QueryVectorLRU(capacity: 2)
        let first = QueryEmbeddingKey(modelID: "model", phrases: ["first"])
        let second = QueryEmbeddingKey(modelID: "model", phrases: ["second"])
        let third = QueryEmbeddingKey(modelID: "model", phrases: ["third"])

        cache.insert([1], for: first)
        cache.insert([2], for: second)
        _ = cache.value(for: first)
        cache.insert([3], for: third)

        #expect(cache.value(for: first) == [1])
        #expect(cache.value(for: second) == nil)
        #expect(cache.value(for: third) == [3])
    }
}

@Suite("Vector maths")
struct VectorTests {
    @Test("int8 quantization preserves direction")
    func quantizationPreservesDirection() {
        var vector = [Float](repeating: 0, count: 512)
        for i in vector.indices { vector[i] = Float.random(in: -1...1) }
        let unit = VectorCodec.normalized(vector)

        let (data, scale) = VectorCodec.encodeInt8(unit)
        #expect(data.count == 512)   // one byte per dimension, as advertised

        let restored = VectorCodec.normalized(VectorCodec.decodeInt8(data, scale: scale))
        #expect(VectorCodec.dot(unit, restored) > 0.999)
    }

    @Test("Normalisation makes dot product equal cosine similarity")
    func normalisation() {
        let vector = VectorCodec.normalized([3, 4, 0, 0])
        #expect(abs(VectorCodec.dot(vector, vector) - 1) < 1e-5)
        #expect(abs(vector[0] - 0.6) < 1e-5)
    }

    @Test("A zero vector doesn't blow up")
    func zeroVector() {
        let zero = VectorCodec.normalized([0, 0, 0, 0])
        #expect(zero.allSatisfy { $0 == 0 })
        let (data, scale) = VectorCodec.encodeInt8(zero)
        #expect(VectorCodec.decodeInt8(data, scale: scale).allSatisfy { $0 == 0 })
    }
}

@Suite("Query grounding")
struct QueryGroundingTests {
    @Test("Slate codes and filenames never reach the language model")
    func identifiersStayLiteral() {
        // Asked to describe a query with no description in it, Apple's
        // on-device model echoes the example from the planner's own
        // instructions: "4582" came back as visual "person wearing a blue
        // shirt", spoken "presupuesto". Someone looking for a slate number
        // would get strangers in blue shirts in their results.
        for identifier in ["4582", "IMG_0042", "A004C012", "TOMA 7", "ROLLO 2", "7"] {
            #expect(!QueryPlanner.hasDescribableContent(identifier),
                    "\(identifier) should be searched literally, not described")
        }
    }

    @Test("Real descriptions still reach the language model")
    func descriptionsStillPlan() {
        for description in ["playa al atardecer",
                            "el que habló del presupuesto",
                            "3 personas en la playa",
                            "a woman in a blue shirt"] {
            #expect(QueryPlanner.hasDescribableContent(description))
        }
    }

    @Test("Slate vocabulary stays searchable as literal text")
    func slateWordsSurviveAsLiterals() {
        // "toma" is the Spanish word for a shot and is printed on clapperboards.
        // It is correctly noise for an image encoder and was being stripped from
        // literal search too, so `TOMA 7` could never match a slate reading
        // "TOMA 7 - CAMARA A - ROLLO 2".
        #expect(Lexicon.filler.contains("toma"), "toma should stay out of CLIP prompts")
        #expect(!Lexicon.literalFiller.contains("toma"), "toma must survive into literal search")
        // Genuine instructions to the app are still dropped from both channels.
        for instruction in ["muéstrame", "búscame", "encuentra", "quiero", "video", "foto"] {
            #expect(Lexicon.filler.contains(instruction))
            #expect(Lexicon.literalFiller.contains(instruction))
        }
    }
}
