import Testing
import Foundation
@testable import WhereFilmCore
@testable import WhereFilmSearch

@Suite("Query filters")
struct QueryFilterTests {
    @Test("Only words that can mean one thing become a media filter")
    func mediaTypeDetection() {
        #expect(QueryFilters.mediaType(in: "fotos de la playa") == .image)
        #expect(QueryFilters.mediaType(in: "videos de entrevista") == .video)
        #expect(QueryFilters.mediaType(in: "photos of the beach") == .image)
        // Nothing about a kind of file: the overwhelmingly common case.
        #expect(QueryFilters.mediaType(in: "el chavo de playera azul") == nil)
        // "Toma" is a take, not a photograph; "imagen" is how a shot looks.
        #expect(QueryFilters.mediaType(in: "la toma del atardecer") == nil)
        #expect(QueryFilters.mediaType(in: "la imagen se ve oscura") == nil)
        // Asking for both is asking for everything.
        #expect(QueryFilters.mediaType(in: "fotos y videos de la boda") == nil)
    }

    @Test("A bare month name is not a date filter")
    func bareMonthIsNotADate() {
        // This is a sentence somebody said. Read as a filter it removes the only
        // file that contains the answer — measured, once, the hard way.
        #expect(QueryFilters.dateRange(in: "la campaña comienza hasta junio") == nil)
        #expect(QueryFilters.dateRange(in: "hablamos de marzo en la reunión") == nil)
    }

    @Test("A month with a year is")
    func monthAndYearIsADate() throws {
        let range = try #require(QueryFilters.dateRange(in: "la entrevista de marzo 2025"))
        let calendar = Calendar.current
        #expect(calendar.component(.year, from: range.lowerBound) == 2025)
        #expect(calendar.component(.month, from: range.lowerBound) == 3)
        #expect(calendar.component(.month, from: range.upperBound) == 3)
    }

    @Test("A bare year covers the whole year")
    func bareYear() throws {
        let range = try #require(QueryFilters.dateRange(in: "todo lo que grabamos en 2024"))
        let calendar = Calendar.current
        #expect(calendar.component(.year, from: range.lowerBound) == 2024)
        #expect(calendar.component(.year, from: range.upperBound) == 2024)
    }

    @Test("Relative dates resolve against a fixed now")
    func relativeDates() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 5
        let now = try #require(Calendar.current.date(from: components))

        let lastYear = try #require(QueryFilters.dateRange(in: "el año pasado", now: now))
        #expect(Calendar.current.component(.year, from: lastYear.lowerBound) == 2025)

        let weeks = try #require(QueryFilters.dateRange(in: "hace tres semanas", now: now))
        #expect(weeks.upperBound <= now)
        #expect(weeks.lowerBound < weeks.upperBound)

        #expect(QueryFilters.dateRange(in: "hace rato", now: now) == nil)
    }
}

@Suite("Channel confidence")
struct ChannelConfidenceTests {
    @Test("Coverage counts how much of the query the text really contains")
    func termCoverage() {
        let terms = ["presupuesto", "segunda", "etapa"]
        #expect(SearchEngine.termCoverage(
            text: "no teníamos presupuesto para la segunda etapa", terms: terms) == 1)
        let partial = SearchEngine.termCoverage(text: "el presupuesto anual", terms: terms)
        #expect(abs(partial - 1.0 / 3.0) < 0.001)
        #expect(SearchEngine.termCoverage(text: "nada que ver", terms: terms) == 0)
    }

    @Test("Coverage ignores accents and case, and honours prefixes")
    func coverageFolds() {
        // The FTS pattern searches `presupuest*`, so the stored word contains it.
        #expect(SearchEngine.termCoverage(text: "PRESUPUESTÓ la campaña",
                                          terms: ["presupuest"]) == 1)
        #expect(SearchEngine.termCoverage(text: "Jorge Álvarez", terms: ["alvarez"]) == 1)
    }

    @Test("A lone weak text hit cannot claim the whole channel")
    func loneHitDoesNotScorePerfectly() {
        // The old min-max normalisation gave a single candidate 1.0 for having no
        // competition. Confidence is absolute now: one matched word out of four,
        // at rank one, is a weak signal and says so.
        let hit = IndexStore.TextHit(
            assetID: 1, momentID: nil, kind: .ocr, startSeconds: 0, endSeconds: 0,
            text: "COTIZACION 4582", snippet: "", score: 1)
        let confidence = SearchEngine.textConfidence(
            hit: hit, position: 0, terms: ["plato", "espagueti", "cocina", "mesa"],
            halfLife: 10)
        #expect(confidence == 0)

        let real = SearchEngine.textConfidence(
            hit: hit, position: 0, terms: ["cotizacion", "4582"], halfLife: 10)
        #expect(real > 0.9)
    }

    @Test("Being the fiftieth answer is weaker than being the first")
    func rankDecays() {
        let hit = IndexStore.TextHit(
            assetID: 1, momentID: nil, kind: .transcript, startSeconds: 0, endSeconds: 0,
            text: "presupuesto", snippet: "", score: 1)
        let first = SearchEngine.textConfidence(hit: hit, position: 0,
                                                terms: ["presupuesto"], halfLife: 10)
        let fiftieth = SearchEngine.textConfidence(hit: hit, position: 49,
                                                   terms: ["presupuesto"], halfLife: 10)
        #expect(first > fiftieth)
        #expect(fiftieth > 0)
    }
}
