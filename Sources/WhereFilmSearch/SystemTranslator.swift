import Foundation
import Translation

/// Spanish → English for the visual half of a query, using the translator macOS
/// already ships.
///
/// The lexicon this replaces is about three hundred hand-written pairs. It was
/// the right first move — it is deterministic, it costs nothing, and it made the
/// Spanish problem visible — but it can only translate words somebody thought of
/// in advance. "Un pato amarillo nadando en el lago" contains four words it has
/// never heard of.
///
/// The system translator has no such limit, runs entirely on-device, and matters
/// most exactly where the on-device language model is missing: an Intel Mac has
/// no Apple Intelligence, and until now that meant falling straight to a
/// three-hundred-word dictionary. Verified on this machine:
///
///     "el chavo de playera azul en la playa de noche"
///         → "The boy in the blue T-shirt on the beach at night"
///     "un pato amarillo nadando en el lago"
///         → "A yellow duck swimming in the lake"
///
/// Both are better than the lexicon can produce, and the second is a sentence
/// the lexicon cannot produce at all.
///
/// Two rules this must never break:
///
///  1. **Only the visual half is translated.** The transcript is in the language
///     that was actually spoken, so translating the spoken terms would be
///     actively harmful. That rule predates this file and outranks it.
///  2. **Unavailable means degrade, never fail.** If the language pair is not
///     installed, this returns nil and the lexicon answers instead. Downloading
///     a language pack needs a UI the search path does not have.
actor SystemTranslator {
    static let shared = SystemTranslator()

    private var statuses: [String: Bool] = [:]
    private var cache: [String: String] = [:]
    /// Bounded so a long session cannot grow it without limit; queries repeat far
    /// more than they vary.
    private let cacheLimit = 512

    /// Whether the pair is installed *right now*. Only `.installed` counts:
    /// `.supported` means the model exists but is not on this Mac, and asking
    /// for it would need a download the search path cannot present.
    func isAvailable(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let key = "\(source.languageCode?.identifier ?? "?")→\(target.languageCode?.identifier ?? "?")"
        if let known = statuses[key] { return known }
        let status = await LanguageAvailability().status(from: source, to: target)
        let installed = status == .installed
        statuses[key] = installed
        return installed
    }

    func translate(_ text: String,
                   from source: Locale.Language = Locale.Language(identifier: "es"),
                   to target: Locale.Language = Locale.Language(identifier: "en")) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = "\(source.languageCode?.identifier ?? "?")|\(trimmed.lowercased())"
        if let cached = cache[key] { return cached }
        guard await isAvailable(from: source, to: target) else { return nil }

        let session = TranslationSession(installedSource: source, target: target)
        guard let response = try? await session.translate(trimmed) else { return nil }
        let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return nil }

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = translated
        return translated
    }

    /// Test seam.
    func forget() {
        cache.removeAll()
        statuses.removeAll()
    }
}
