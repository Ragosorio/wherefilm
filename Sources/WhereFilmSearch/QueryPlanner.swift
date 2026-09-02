import Foundation
import NaturalLanguage
import FoundationModels
import WhereFilmCore

/// What a natural-language query is decomposed into before it touches any index.
public struct SearchPlan: Sendable {
    public var rawQuery: String
    /// English phrases for the CLIP text encoder. Several phrasings get averaged,
    /// which widens recall cheaply.
    public var visualPhrases: [String]
    /// Terms to look for in the transcript, **in the language it was spoken**.
    /// Translating these would be actively harmful.
    public var spokenTerms: [String]
    /// Terms for on-screen text, filenames and folders.
    public var literalTerms: [String]
    public var mediaType: MediaType?
    public var dateRange: ClosedRange<Date>?
    /// Which tier produced this plan — surfaced in `--explain` so the behaviour
    /// is never a black box.
    public var source: PlanSource

    public enum PlanSource: String, Sendable {
        case foundationModel = "Apple on-device model"
        case lexicon = "built-in lexicon"
        case literal = "literal query"
    }

    public var hasVisualSignal: Bool { !visualPhrases.isEmpty }
    public var hasTextSignal: Bool { !spokenTerms.isEmpty || !literalTerms.isEmpty }
}

/// Turns "el chavo de playera azul que habló del presupuesto" into something the
/// indexes can answer.
///
/// Three tiers, each degrading cleanly into the next, because Apple Intelligence
/// is not on every Mac and the product must not require it:
///
///  1. The on-device Foundation Model, with structured output.
///  2. A built-in Spanish→English lexicon of audiovisual vocabulary.
///  3. The query as typed.
///
/// The LLM never touches the indexing hot path. It runs once, per search, for a
/// few hundred milliseconds — which is exactly where a language model earns its
/// keep without becoming the heart of the system.
public struct QueryPlanner: Sendable {
    public var useFoundationModel: Bool

    public init(useFoundationModel: Bool = true) {
        self.useFoundationModel = useFoundationModel
    }

    public static var foundationModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public static var foundationModelStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            "available"
        case .unavailable(.deviceNotEligible):
            "unavailable — this Mac does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            "unavailable — Apple Intelligence is turned off in System Settings"
        case .unavailable(.modelNotReady):
            "unavailable — the model is still downloading"
        case .unavailable(let reason):
            "unavailable — \(reason)"
        }
    }

    public func plan(_ query: String) async -> SearchPlan {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchPlan(rawQuery: query, visualPhrases: [], spokenTerms: [],
                              literalTerms: [], mediaType: nil, dateRange: nil, source: .literal)
        }

        // A query made only of identifiers has nothing for a language model to
        // describe, and asking anyway is not merely wasted — it is actively
        // wrong. Measured on this build, Apple's on-device model answered:
        //
        //     "TOMA 7"    → visual "Two women standing together…"
        //     "IMG_0042"  → visual "person wearing a blue shirt"
        //     "4582"      → visual "person wearing a blue shirt",
        //                   spoken "presupuesto"
        //
        // Those last two are the example sentence from the planner's own
        // instructions, echoed back because the query gave the model nothing
        // else to work with. Someone searching for a slate number would get
        // shots of people in blue shirts ranked into their results.
        //
        // Slate codes, roll numbers and filenames are exactly what literal
        // search is for, and it answers them in ~80 ms instead of ~1.4 s.
        if useFoundationModel, Self.foundationModelAvailable,
           Self.hasDescribableContent(trimmed),
           let plan = try? await planWithFoundationModel(trimmed) {
            return plan
        }
        return lexiconPlan(trimmed)
    }

    /// Whether the query says anything a model could turn into a scene.
    ///
    /// A token carrying a digit is an identifier — `IMG_0042`, `A004C012`, `7`.
    /// A token that is grammar (`filler`) or slate vocabulary (`toma`, `rollo`,
    /// `camara`) is meaningful to search literally and meaningless as a
    /// description. If nothing else is left, there is no scene to describe.
    static func hasDescribableContent(_ query: String) -> Bool {
        // Split on whitespace only. `IMG_0042` is one identifier, not a word
        // called "img" next to a number, and splitting it made the guard let
        // exactly that case through.
        for raw in query.split(whereSeparator: \.isWhitespace) {
            if raw.contains(where: \.isNumber) { continue }
            let word = Lexicon.fold(String(raw)).trimmingCharacters(in: .whitespaces)
            guard word.count >= 3,
                  !Lexicon.filler.contains(word),
                  !Lexicon.slateVocabulary.contains(word) else { continue }
            return true
        }
        return false
    }

    // MARK: - Tier 1

    @Generable
    struct ModelPlan {
        @Guide(description: "A short English phrase containing ONLY what is visibly observable in the shot: people, clothing, colours, place, time of day. Exclude topics or words that are merely spoken, such as a budget mentioned in dialogue. Empty if the query says nothing about appearance.")
        var visual: String

        @Guide(description: "An alternative English phrasing of the same strictly visible scene, using different words. Never include dialogue topics. Empty if there is no visual part.")
        var visualAlternative: String

        @Guide(description: "Words the speaker would have SAID, written in the SAME LANGUAGE as the query — if the query is Spanish these MUST be Spanish. Comma separated, with close synonyms. Never translate these. Empty if the query says nothing about speech.")
        var spoken: String

        @Guide(description: "One of: video, image, audio, any")
        var mediaType: String
    }

    private func planWithFoundationModel(_ query: String) async throws -> SearchPlan {
        let session = LanguageModelSession(instructions: """
            You split media search queries into separate signals for a video search engine.
            The engine matches pictures with an English image-text model, and matches speech \
            against transcripts that are in the language actually spoken.
            So: describe only directly observable VISIBLE details in English, and keep the \
            SPOKEN part in the query's own language. A spoken topic is never a visible \
            detail: for "persona con camisa azul que habló del presupuesto", visual is \
            "person wearing a blue shirt" and spoken is "presupuesto". Never invent details.
            """)

        let response = try await session.respond(to: query, generating: ModelPlan.self)
        let plan = response.content

        var visualPhrases = [plan.visual, plan.visualAlternative]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !Self.isEmptySentinel($0) }
            // The model is asked for English and is non-deterministic about it.
            // An untranslated phrase reaching the English-only text encoder is
            // the single worst failure this planner can produce, so every phrase
            // goes past the lexicon on its way out.
            .map { phrase in
                guard Lexicon.needsTranslation(phrase) else { return phrase }
                let translated = Lexicon.translateVisual(phrase)
                return translated.isEmpty ? phrase : translated
            }
        // Deduplicate without reordering: the first phrase is the model's best.
        var seen = Set<String>()
        visualPhrases = visualPhrases.filter { seen.insert($0.lowercased()).inserted }

        let literalTerms = Self.literalTerms(from: query)
        // The model's spoken terms are treated as *additions*, never as a
        // replacement. It sometimes translates them despite being told not to,
        // and the transcript is in the language that was actually spoken — so the
        // original words always stay in the query. The LLM can only improve this
        // search; it can never break it.
        var spokenTerms = literalTerms
        for term in plan.spoken.split(separator: ",") {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count > 2, !Self.isEmptySentinel(cleaned),
                  !spokenTerms.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame })
            else { continue }
            spokenTerms.append(cleaned)
        }

        return SearchPlan(
            rawQuery: query,
            visualPhrases: visualPhrases,
            spokenTerms: spokenTerms,
            literalTerms: literalTerms,
            mediaType: MediaType(rawValue: plan.mediaType.lowercased()),
            dateRange: nil,
            source: .foundationModel)
    }

    // MARK: - Tier 2 and 3

    func lexiconPlan(_ query: String) -> SearchPlan {
        let language = NLLanguageRecognizer.dominantLanguage(for: query)
        let isSpanish = language == .spanish || Lexicon.looksSpanish(query)

        var visualPhrases: [String] = []
        if isSpanish {
            let translated = Lexicon.translateVisual(query)
            if !translated.isEmpty { visualPhrases.append(translated) }
            // Keep the original too: proper nouns and brand names survive better
            // untranslated, and CLIP has seen plenty of them.
            visualPhrases.append(query)
        } else {
            visualPhrases.append(query)
        }

        // Everything meaningful in the query is a candidate transcript term. FTS5
        // ranking sorts out which ones actually matter.
        let terms = Self.literalTerms(from: query)

        return SearchPlan(
            rawQuery: query,
            visualPhrases: visualPhrases,
            spokenTerms: terms,
            literalTerms: terms,
            mediaType: nil,
            dateRange: nil,
            source: isSpanish ? .lexicon : .literal)
    }

    /// A structured-output field asked to be "empty" is not always empty.
    ///
    /// Observed from the on-device model: it answers the field named `spoken`
    /// with the literal text "no spoken". Left alone that becomes a transcript
    /// search term and quietly poisons the text half of every such query.
    static func isEmptySentinel(_ text: String) -> Bool {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
        if folded.isEmpty { return true }
        let sentinels: Set<String> = [
            "none", "n/a", "na", "null", "nil", "empty", "no visual", "no spoken",
            "no dialogue", "no speech", "no text", "not applicable", "nothing",
            "ninguno", "ninguna", "nada", "vacio", "vacío", "sin dialogo",
            "sin diálogo", "no aplica",
        ]
        return sentinels.contains(folded)
    }

    static func literalTerms(from query: String) -> [String] {
        // Quoted runs stay intact: "no había presupuesto" should be searched as a
        // phrase, not as three loose words.
        var terms: [String] = []
        var remainder = query

        let quoted = try? NSRegularExpression(pattern: "[\"“”']([^\"“”']{2,})[\"“”']")
        if let quoted {
            let range = NSRange(query.startIndex..., in: query)
            for match in quoted.matches(in: query, range: range).reversed() {
                guard let phraseRange = Range(match.range(at: 1), in: query),
                      let fullRange = Range(match.range, in: remainder) else { continue }
                terms.append(String(query[phraseRange]))
                remainder.removeSubrange(fullRange)
            }
        }

        terms += Lexicon.fold(remainder)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !Lexicon.literalFiller.contains($0) }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }
}
