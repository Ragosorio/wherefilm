import Foundation

/// The byte-level BPE tokenizer CLIP (and therefore MobileCLIP) expects.
///
/// The text encoder takes exactly 77 int32 tokens, so this has to match the
/// reference implementation byte for byte. Verified against
/// `openai/clip-vit-base-patch32`:
///
///     "a photo of a cat"        → [49406, 320, 1125, 539, 320, 2368, 49407]
///     "man wearing a blue shirt"→ [49406, 786, 3309, 320, 1746, 2523, 49407]
///
/// It also shows exactly why Spanish queries under-perform: *man* is one token,
/// while *hombre* splits into `hom` + `bre</w>`. That is what the query planner
/// in WhereFilmSearch exists to fix.
public struct CLIPTokenizer: Sendable {
    public static let contextLength = 77
    public static let startOfText = 49406
    public static let endOfText = 49407

    private let encoder: [String: Int]
    private let bpeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: String]
    private let pattern: NSRegularExpression

    struct Pair: Hashable {
        let first: String
        let second: String
    }

    public enum TokenizerError: Error, LocalizedError {
        case missingAssets(URL)

        public var errorDescription: String? {
            switch self {
            case .missingAssets(let url):
                "Tokenizer assets not found in \(url.path). Run Scripts/fetch-models.sh."
            }
        }
    }

    /// Loads `clip-vocab.json` and `clip-merges.txt` from the models directory.
    /// They are downloaded by `Scripts/fetch-models.sh` rather than vendored, to
    /// keep the repository small and the licensing clean.
    public init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("clip-vocab.json")
        let mergesURL = directory.appendingPathComponent("clip-merges.txt")
        guard FileManager.default.fileExists(atPath: vocabURL.path),
              FileManager.default.fileExists(atPath: mergesURL.path) else {
            throw TokenizerError.missingAssets(directory)
        }

        encoder = try JSONDecoder().decode(
            [String: Int].self, from: Data(contentsOf: vocabURL))

        var ranks: [Pair: Int] = [:]
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        var rank = 0
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(first: String(parts[0]), second: String(parts[1]))] = rank
            rank += 1
        }
        bpeRanks = ranks
        byteEncoder = Self.makeByteEncoder()
        pattern = try NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])
    }

    /// Full encode: SOT + tokens + EOT, zero-padded (and truncated) to 77.
    public func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = [Int32(Self.startOfText)]
        tokens.append(contentsOf: tokenIDs(text).map(Int32.init))

        let maxBody = Self.contextLength - 2
        if tokens.count > maxBody + 1 {
            tokens = Array(tokens.prefix(maxBody + 1))
        }
        tokens.append(Int32(Self.endOfText))

        if tokens.count < Self.contextLength {
            tokens.append(contentsOf: [Int32](
                repeating: 0, count: Self.contextLength - tokens.count))
        }
        return tokens
    }

    /// Token ids without the special tokens or padding — handy for tests and for
    /// reasoning about why a query tokenizes badly.
    public func tokenIDs(_ text: String) -> [Int] {
        var result: [Int] = []
        for chunk in split(cleaned(text)) {
            // Byte-level: every UTF-8 byte maps to a printable stand-in, so any
            // input is representable no matter the script.
            let mapped = chunk.utf8.map { byteEncoder[$0] ?? "" }.joined()
            for piece in bpe(mapped).split(separator: " ") {
                if let id = encoder[String(piece)] { result.append(id) }
            }
        }
        return result
    }

    // MARK: - Internals

    private func cleaned(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    private func split(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private func bpe(_ token: String) -> String {
        guard !token.isEmpty else { return token }

        // CLIP marks the end of a word by suffixing the *last* character.
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"
        if word.count == 1 { return word[0] }

        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(word.count - 1) {
                let pair = Pair(first: word[i], second: word[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }

            let merged = word[bestIndex] + word[bestIndex + 1]
            word.replaceSubrange(bestIndex...(bestIndex + 1), with: [merged])
            if word.count == 1 { break }
        }
        return word.joined(separator: " ")
    }

    /// GPT-2's `bytes_to_unicode`: maps all 256 byte values to printable
    /// characters so the BPE vocabulary never has to contain raw control bytes.
    private static func makeByteEncoder() -> [UInt8: String] {
        var byteValues: [UInt8] = []
        byteValues.append(contentsOf: UInt8(33)...UInt8(126))
        byteValues.append(contentsOf: UInt8(161)...UInt8(172))
        byteValues.append(contentsOf: UInt8(174)...UInt8(255))

        var mapping: [UInt8: String] = [:]
        for byte in byteValues {
            mapping[byte] = String(UnicodeScalar(byte))
        }
        var next = 0
        for value in 0...255 {
            let byte = UInt8(value)
            if mapping[byte] == nil {
                mapping[byte] = String(UnicodeScalar(256 + next)!)
                next += 1
            }
        }
        return mapping
    }
}
