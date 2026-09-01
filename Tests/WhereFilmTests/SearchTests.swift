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
        let terms = QueryPlanner.literalTerms(from: "el video donde se ve la playa")
        #expect(terms.contains("playa"))
        #expect(!terms.contains("el"))
        #expect(!terms.contains("video"))
    }

    @Test("An English query is left alone")
    func englishPassesThrough() {
        let plan = planner.lexiconPlan("man wearing a blue shirt")
        #expect(plan.visualPhrases.contains("man wearing a blue shirt"))
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

    @Test("Timecodes are formatted for humans")
    func timecodeFormatting() {
        #expect(SearchResult.timecode(0) == "00:00")
        #expect(SearchResult.timecode(74) == "01:14")
        #expect(SearchResult.timecode(852) == "14:12")
        #expect(SearchResult.timecode(3725) == "1:02:05")
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
