import Foundation
import WhereFilmCore

/// The parts of a query that are not "what did it look like" or "what was said"
/// but "which files are even eligible".
///
/// The query planner has produced `mediaType` and `dateRange` since the first
/// version, and the search engine has never once read them. Turning them on
/// naively would have been worse than leaving them off: the on-device model
/// fills in `mediaType` on almost every query, including when the query says
/// nothing about it, and a wrong hard filter does not degrade a search — it
/// empties it.
///
/// So filters are detected here, deterministically, from words that can only
/// mean one thing. The language model's opinion is accepted only when it agrees
/// with something explicit in the text. That keeps the rule the planner already
/// lives by: the model may improve a search, never break one.
public enum QueryFilters {
    /// Words that unambiguously name a kind of file.
    ///
    /// Deliberately narrow. "Toma" means a take, "imagen" can mean the look of
    /// a shot, and "grabación" can be either — none of them are here.
    static let imageWords: Set<String> = [
        "foto", "fotos", "fotografia", "fotografias", "photo", "photos",
        "photograph", "photographs", "still", "stills",
    ]
    static let videoWords: Set<String> = [
        "video", "videos", "clip", "clips", "metraje", "footage", "pietaje",
    ]
    static let audioWords: Set<String> = [
        "audio", "audios", "podcast", "grabacion de audio", "voice memo",
    ]

    /// `nil` when the query says nothing about it — which is most of the time,
    /// and is the whole point.
    public static func mediaType(in query: String) -> MediaType? {
        let words = Set(Lexicon.fold(query).split(separator: " ").map(String.init))
        let isImage = !words.isDisjoint(with: imageWords)
        let isVideo = !words.isDisjoint(with: videoWords)
        let isAudio = !words.isDisjoint(with: audioWords)
        // "fotos y videos" is not a filter, it is a person saying "everything".
        guard [isImage, isVideo, isAudio].filter({ $0 }).count == 1 else { return nil }
        if isImage { return .image }
        if isVideo { return .video }
        return .audio
    }

    static let months: [String: Int] = [
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6,
        "julio": 7, "agosto": 8, "septiembre": 9, "setiembre": 9, "octubre": 10,
        "noviembre": 11, "diciembre": 12,
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
        "december": 12,
    ]

    /// Recognises the date shapes people actually type about footage.
    ///
    /// Only closed, unambiguous ones. "El verano pasado" is a season in a
    /// hemisphere nobody stated; "hace un rato" is not a date.
    public static func dateRange(in query: String, now: Date = Date(),
                                 calendar: Calendar = .current) -> ClosedRange<Date>? {
        let folded = Lexicon.fold(query)
        let words = folded.split(separator: " ").map(String.init)

        func range(year: Int, month: Int? = nil) -> ClosedRange<Date>? {
            var start = DateComponents()
            start.year = year
            start.month = month ?? 1
            start.day = 1
            guard let from = calendar.date(from: start) else { return nil }
            let span = month == nil
                ? DateComponents(year: 1, second: -1)
                : DateComponents(month: 1, second: -1)
            guard let to = calendar.date(byAdding: span, to: from) else { return nil }
            return from...to
        }

        // "marzo 2025" / "en marzo de 2025" / "march 2025"
        let years = words.compactMap { word -> Int? in
            guard word.count == 4, let value = Int(word), (1990...2100).contains(value)
            else { return nil }
            return value
        }
        let namedMonths = words.compactMap { months[$0] }

        if let year = years.first {
            if let month = namedMonths.first { return range(year: year, month: month) }
            return range(year: year)
        }

        let currentYear = calendar.component(.year, from: now)

        // "el año pasado" / "last year"
        if folded.contains("ano pasado") || folded.contains("last year") {
            return range(year: currentYear - 1)
        }
        if folded.contains("este ano") || folded.contains("this year") {
            return range(year: currentYear)
        }
        // A bare month name is deliberately NOT a filter, and this cost a
        // regression to learn. "La campaña comienza hasta junio" is a sentence
        // somebody said, not a request for files created in June — and read as a
        // date it removed the only asset that contained the answer, taking the
        // case from rank 1 to nowhere at all. A month qualifies as a filter only
        // when a year says it is one.

        // "hace 3 semanas" / "hace dos meses"
        if let relative = relativeRange(words: words, now: now, calendar: calendar) {
            return relative
        }
        return nil
    }

    static let smallNumbers: [String: Int] = [
        "un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
        "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "doce": 12,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    ]

    private static func relativeRange(words: [String], now: Date,
                                      calendar: Calendar) -> ClosedRange<Date>? {
        guard let anchor = words.firstIndex(where: { $0 == "hace" || $0 == "ago" })
        else { return nil }
        // "hace 3 semanas" reads forward; "3 weeks ago" reads backward.
        let neighbours = words[max(0, anchor - 2)...min(words.count - 1, anchor + 2)]
        var amount: Int?
        var unit: Calendar.Component?
        for word in neighbours {
            if let value = Int(word) ?? smallNumbers[word] { amount = amount ?? value }
            switch word {
            case "dia", "dias", "day", "days": unit = unit ?? .day
            case "semana", "semanas", "week", "weeks": unit = unit ?? .weekOfYear
            case "mes", "meses", "month", "months": unit = unit ?? .month
            case "ano", "anos", "year", "years": unit = unit ?? .year
            default: break
            }
        }
        guard let amount, let unit, amount > 0,
              let from = calendar.date(byAdding: unit, value: -amount, to: now)
        else { return nil }
        // A window, not an instant: "hace tres semanas" means around then.
        let padding: Calendar.Component = unit == .day ? .day : .weekOfYear
        guard let lower = calendar.date(byAdding: padding, value: -1, to: from),
              let upper = calendar.date(byAdding: padding, value: 1, to: from)
        else { return nil }
        return lower...min(upper, now)
    }
}
