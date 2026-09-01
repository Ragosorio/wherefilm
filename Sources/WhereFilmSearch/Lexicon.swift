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
    static let filler: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "que",
        "donde", "cuando", "con", "y", "o", "en", "a", "al", "se", "su", "sus",
        "es", "era", "esta", "este", "esa", "ese", "lo", "por", "para", "muy",
        "aparece", "sale", "salía", "video", "clip", "toma", "busca", "buscar",
        "encuentra", "encontrar", "acuerdas", "acuerdo", "recuerdas",
    ]

    private static let sorted = spanishToEnglish.sorted { $0.es.count > $1.es.count }

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

    /// Lowercase and strip accents so "camisa" and "cámara" behave predictably —
    /// the same normalisation FTS5 does with `remove_diacritics 2`.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}
