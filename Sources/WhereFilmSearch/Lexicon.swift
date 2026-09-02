import Foundation

/// A small Spanish→English lexicon for the vocabulary people actually use when
/// describing footage.
///
/// This exists because MobileCLIP v1 is an English model. Its tokenizer makes
/// the problem visible: *man* is a single token, while *hombre* splits into
/// `hom` + `bre</w>`. Rather than paying for a multilingual model an order of
/// magnitude larger, the query gets translated on its way to the text encoder —
/// and only the *visual* half of the query, never the spoken half, because the
/// transcript is genuinely in Spanish.
///
/// This is the always-available tier. When Apple Intelligence is present the
/// on-device model does a far better job; this is the floor, not the ceiling.
public enum Lexicon {
    /// Longest phrases first, so "playera azul" wins over "playera" alone.
    public static let spanishToEnglish: [(es: String, en: String)] = [
        // People
        ("chavo", "young man"), ("chava", "young woman"),
        ("muchacho", "young man"), ("muchacha", "young woman"),
        ("hombre", "man"), ("mujer", "woman"), ("señor", "man"), ("señora", "woman"),
        ("niño", "child"), ("niña", "child"), ("niños", "children"),
        ("gente", "people"), ("persona", "person"), ("personas", "people"),
        ("multitud", "crowd"), ("público", "audience"), ("equipo", "team"),
        ("anciano", "elderly man"), ("anciana", "elderly woman"),

        // Clothing
        ("playera", "t-shirt"), ("camisa", "shirt"), ("camiseta", "t-shirt"),
        ("chamarra", "jacket"), ("chaqueta", "jacket"), ("saco", "suit jacket"),
        ("traje", "suit"), ("corbata", "tie"), ("vestido", "dress"),
        ("gorra", "cap"), ("sombrero", "hat"), ("lentes", "glasses"),
        ("gafas", "glasses"), ("casco", "helmet"), ("uniforme", "uniform"),
        ("chaleco", "vest"), ("sudadera", "hoodie"), ("pantalón", "trousers"),
        ("zapatos", "shoes"), ("mochila", "backpack"), ("gafete", "badge"),

        // Colours
        ("azul", "blue"), ("roja", "red"), ("rojo", "red"),
        ("verde", "green"), ("amarilla", "yellow"), ("amarillo", "yellow"),
        ("negra", "black"), ("negro", "black"), ("blanca", "white"), ("blanco", "white"),
        ("gris", "grey"), ("café", "brown"), ("morado", "purple"), ("rosa", "pink"),
        ("naranja", "orange"), ("dorado", "golden"), ("plateado", "silver"),

        // Scenes and places
        ("entrevista", "interview"), ("entrevistando", "interviewing"),
        ("oficina", "office"), ("calle", "street"), ("carretera", "road"),
        ("playa", "beach"), ("montaña", "mountain"), ("bosque", "forest"),
        ("ciudad", "city"), ("campo", "countryside"), ("cocina", "kitchen"),
        ("restaurante", "restaurant"), ("mercado", "market"), ("tienda", "shop"),
        ("escuela", "school"), ("hospital", "hospital"), ("iglesia", "church"),
        ("estadio", "stadium"), ("concierto", "concert"), ("boda", "wedding"),
        ("fiesta", "party"), ("reunión", "meeting"), ("conferencia", "conference"),
        ("set", "film set"), ("estudio", "studio"), ("escenario", "stage"),

        // Objects
        ("carro", "car"), ("coche", "car"), ("auto", "car"),
        ("camión", "truck"), ("moto", "motorcycle"), ("bicicleta", "bicycle"),
        ("avión", "airplane"), ("barco", "boat"), ("tren", "train"),
        ("cámara", "camera"), ("micrófono", "microphone"), ("computadora", "computer"),
        ("teléfono", "phone"), ("celular", "mobile phone"), ("pantalla", "screen"),
        ("letrero", "sign"), ("cartel", "poster"), ("pizarra", "whiteboard"),
        ("mesa", "table"), ("silla", "chair"), ("puerta", "door"), ("ventana", "window"),
        ("comida", "food"), ("perro", "dog"), ("gato", "cat"), ("caballo", "horse"),
        ("olas", "waves"), ("ola", "wave"), ("arena", "sand"), ("mar", "sea"),
        ("cielo", "sky"), ("nubes", "clouds"), ("árbol", "tree"), ("árboles", "trees"),
        ("flores", "flowers"), ("río", "river"), ("lago", "lake"), ("puente", "bridge"),
        ("edificio", "building"), ("desierto", "desert"), ("acantilado", "cliff"),

        // Light and time of day
        ("de noche", "at night"), ("de día", "during the day"),
        ("noche", "night"), ("día", "day"),
        ("atardecer", "sunset"), ("amanecer", "sunrise"),
        ("lluvia", "rain"), ("lloviendo", "raining"), ("nieve", "snow"),
        ("sol", "sun"), ("soleado", "sunny"), ("nublado", "cloudy"),
        ("oscuro", "dark"), ("iluminado", "brightly lit"),
        ("interior", "indoors"), ("exterior", "outdoors"),

        // Camera language
        ("plano cerrado", "close-up shot"), ("primer plano", "close-up"),
        ("plano abierto", "wide shot"), ("plano general", "wide establishing shot"),
        ("plano medio", "medium shot"), ("contrapicado", "low angle shot"),
        ("picado", "high angle shot"), ("toma aérea", "aerial shot"),
        ("dron", "drone shot"), ("cámara lenta", "slow motion"),
        ("blanco y negro", "black and white"),

        // Actions
        ("hablando", "talking"), ("caminando", "walking"), ("corriendo", "running"),
        ("sentado", "sitting"), ("parado", "standing"), ("bailando", "dancing"),
        ("cantando", "singing"), ("comiendo", "eating"), ("trabajando", "working"),
        ("manejando", "driving"), ("sonriendo", "smiling"), ("llorando", "crying"),
        ("aplaudiendo", "applauding"), ("escribiendo", "writing"),
        ("presentando", "presenting"), ("firmando", "signing"),
    ]

    /// Stop words that add nothing to a CLIP prompt.
    ///
    /// Anything left here reaches the text encoder as noise, so the list covers
    /// the connectives and auxiliaries that actually show up when someone
    /// describes a shot out loud — not a textbook stop-word list.
    static let filler: Set<String> = [
        // Articles, pronouns, basic prepositions
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "que",
        "donde", "cuando", "con", "y", "e", "o", "u", "en", "entre", "a", "al",
        "se", "su", "sus", "mi", "mis", "tu", "tus", "lo", "por", "para", "muy",
        "es", "era", "esta", "este", "esa", "ese", "esto", "eso", "estos", "esas",
        // Connectives that survive translation as literal noise
        "junto", "juntos", "junta", "sobre", "bajo", "hacia", "desde", "hasta",
        "sin", "tras", "ante", "contra", "durante", "mientras", "pero", "aunque",
        "tambien", "también", "solo", "sólo", "mas", "más", "menos", "algo",
        "todo", "toda", "todos", "todas", "cual", "cuales", "quien", "quienes",
        "como", "cómo", "hay", "son", "fue", "fueron", "estan", "están", "tiene",
        // Search-box verbs: instructions to the app, never part of the scene
        "aparece", "aparecen", "sale", "salen", "salía", "video", "vídeo", "clip",
        "toma", "busca", "buscar", "buscame", "búscame", "encuentra", "encontrar",
        "acuerdas", "acuerdo", "recuerdas", "recuerdo", "necesito", "quiero",
        "muestrame", "muéstrame", "dame", "foto", "fotos", "imagen", "imagenes",
        "imágenes", "archivo", "archivos", "momento", "momentos", "parte",
    ]

    /// Words a Spanish-speaking crew writes on a clapperboard.
    ///
    /// These are meaningless to an image encoder and essential to literal
    /// search, so they need to be recognised as neither description nor noise
    /// but as *identifiers*. A slate reading `TOMA 7 - CAMARA A - ROLLO 2` is
    /// findable only if these survive into the literal channel, and a query made
    /// only of them has nothing in it for a language model to describe.
    static let slateVocabulary: Set<String> = [
        "toma", "tomas", "rollo", "rollos", "camara", "cámara", "camaras",
        "cámaras", "escena", "escenas", "plano", "planos", "claqueta",
        "secuencia", "secuencias",
    ]

    /// The subset of `filler` that is also noise in a *literal* search.
    ///
    /// `filler` exists to keep junk out of a CLIP prompt, and for that job
    /// "toma" is correctly noise — no image encoder is helped by it. But the
    /// same list was stripping literal terms, and literal terms are what match
    /// slates, filenames and on-screen text, where "toma" is the entire point.
    ///
    /// The effect was that `TOMA 7` could never find a slate reading
    /// `TOMA 7 - CAMARA A - ROLLO 2`, in a tool built for crews who call a shot
    /// a toma. Worse, stripping the query to nothing sent an empty request to
    /// the planner, which filled the void with the example from its own
    /// instructions. Genuine instructions to the app — "muéstrame", "búscame" —
    /// are still dropped from both channels.
    static let literalFiller: Set<String> = filler.subtracting(slateVocabulary)

    /// The table above plus every plural that Spanish morphology produces from
    /// it, longest first so multi-word phrases still win over their parts.
    ///
    /// Hand-listing plurals would double the table and guarantee gaps; a real
    /// person types "acantilados" and "árboles" far more often than the
    /// dictionary singular.
    static let sorted: [(es: String, en: String)] = {
        var table = spanishToEnglish
        var known = Set(spanishToEnglish.map { fold($0.es) })
        for entry in spanishToEnglish {
            for plural in spanishPlurals(of: entry.es) where known.insert(fold(plural)).inserted {
                table.append((es: plural, en: englishPlural(of: entry.en)))
            }
        }
        return table.sorted { $0.es.count > $1.es.count }
    }()

    /// Spanish pluralisation, covering the three rules that matter:
    /// vowel + *s*, consonant + *es*, and final *z* → *ces*.
    static func spanishPlurals(of singular: String) -> [String] {
        // Multi-word phrases ("plano cerrado") are camera language, not nouns
        // people pluralise in a search box.
        guard !singular.contains(" "), let last = singular.last else { return [] }
        switch last {
        case "a", "e", "i", "o", "u", "á", "é", "í", "ó", "ú":
            return [singular + "s"]
        case "z":
            return [singular.dropLast() + "ces"]
        case "s":
            return []  // already plural, or invariant ("lentes", "gafas")
        default:
            // "mujer" → "mujeres", and the unaccented form too, because a
            // search box rarely carries accents: "arbol" → "arboles".
            return [singular + "es"]
        }
    }

    /// English pluralisation, only as good as a CLIP prompt needs. The image
    /// model is unbothered by number, so a wrong guess costs recall, not
    /// correctness — but "cliffs" reads more like the shot than "cliff".
    static func englishPlural(of phrase: String) -> String {
        // Only the head noun of a short phrase; anything longer is left alone
        // rather than mangled ("close-up shot" stays as it is).
        guard !phrase.contains(" "), let last = phrase.last else { return phrase }
        if phrase.hasSuffix("s") || phrase.hasSuffix("ch") || phrase.hasSuffix("sh") {
            return phrase + "es"
        }
        if last == "y", let previous = phrase.dropLast().last, !"aeiou".contains(previous) {
            return phrase.dropLast() + "ies"
        }
        return phrase + "s"
    }

    /// Word-for-word translation of the visual part of a query. Crude, and
    /// deliberately so — CLIP responds to a bag of concrete nouns and adjectives,
    /// not to grammar.
    public static func translateVisual(_ text: String) -> String {
        var working = " " + fold(text) + " "
        for entry in sorted {
            let needle = " " + fold(entry.es) + " "
            guard working.contains(needle) else { continue }
            working = working.replacingOccurrences(of: needle, with: " \(entry.en) ")
        }
        let words = working
            .split(separator: " ")
            .map(String.init)
            .filter { !filler.contains($0) }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Does this query contain enough Spanish that translating is worth it?
    public static func looksSpanish(_ text: String) -> Bool {
        let words = Set(fold(text).split(separator: " ").map(String.init))
        if !words.isDisjoint(with: filler) { return true }
        return sorted.contains { words.contains(fold($0.es)) }
    }

    /// Is this phrase still Spanish *after* something claimed to translate it?
    ///
    /// The on-device model is asked for English and usually delivers, but it is
    /// non-deterministic: the same query can come back translated once and
    /// verbatim the next time. Sending Spanish to an English-only text encoder
    /// silently wrecks a search, so the answer gets checked rather than trusted.
    public static func needsTranslation(_ phrase: String) -> Bool {
        let words = fold(phrase).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let spanishHits = words.filter { word in
            filler.contains(word) || sorted.contains { fold($0.es) == word }
        }
        // One Spanish word in a long English phrase is usually a proper noun or
        // a loanword. A third of them is a phrase that never got translated.
        return Double(spanishHits.count) / Double(words.count) >= 0.34
    }

    /// Lowercase and strip accents so "camisa" and "cámara" behave predictably —
    /// the same normalisation FTS5 does with `remove_diacritics 2`.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}
