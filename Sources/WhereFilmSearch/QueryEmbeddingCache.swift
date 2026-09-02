import Foundation
import WhereFilmML

/// Small, process-local cache for the expensive half of a visual query.
///
/// A query vector is only 2 KB, so keeping a few recent vectors is much cheaper
/// than loading the 81 MB text model and encoding the same prefix repeatedly.
/// The model itself is released after a short idle period; idle memory remains
/// small while a burst of typing stays warm.
protocol QueryEmbeddingProviding: Sendable {
    func embedding(for phrases: [String], variant: MobileCLIPVariant) async throws -> [Float]
}

struct QueryEmbeddingKey: Hashable {
    let modelID: String
    let phrases: [String]
}

/// Tiny value-only LRU, separated from Core ML so eviction and model-version
/// invalidation remain deterministic and unit-testable.
struct QueryVectorLRU {
    private let capacity: Int
    private var values: [QueryEmbeddingKey: [Float]] = [:]
    private var recency: [QueryEmbeddingKey] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: QueryEmbeddingKey) -> [Float]? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: [Float], for key: QueryEmbeddingKey) {
        values[key] = value
        touch(key)
        while recency.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    var count: Int { values.count }

    private mutating func touch(_ key: QueryEmbeddingKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

actor QueryEmbeddingCache: QueryEmbeddingProviding {
    static let shared = QueryEmbeddingCache()

    private let modelIdleSeconds: TimeInterval
    private var vectors: QueryVectorLRU
    private var encoders: [String: MobileCLIPTextEncoder] = [:]
    private var encoderGeneration = 0

    init(capacity: Int = 128, modelIdleSeconds: TimeInterval = 45) {
        self.vectors = QueryVectorLRU(capacity: capacity)
        self.modelIdleSeconds = max(0, modelIdleSeconds)
    }

    func embedding(for phrases: [String], variant: MobileCLIPVariant) async throws -> [Float] {
        try Task.checkCancellation()
        let key = QueryEmbeddingKey(modelID: variant.modelID, phrases: Self.canonical(phrases))
        guard !key.phrases.isEmpty else { return [] }

        if let cached = vectors.value(for: key) { return cached }

        let encoder: MobileCLIPTextEncoder
        if let loaded = encoders[variant.modelID] {
            encoder = loaded
        } else {
            encoder = try MobileCLIPTextEncoder(variant: variant)
            encoders[variant.modelID] = encoder
        }

        try Task.checkCancellation()
        let vector = try encoder.encodeEnsemble(phrases)
        try Task.checkCancellation()

        vectors.insert(vector, for: key)
        scheduleEncoderRelease()
        return vector
    }

    var count: Int { vectors.count }

    private func scheduleEncoderRelease() {
        encoderGeneration += 1
        let generation = encoderGeneration
        let delay = modelIdleSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.releaseEncoders(ifGenerationIs: generation)
        }
    }

    private func releaseEncoders(ifGenerationIs generation: Int) {
        guard generation == encoderGeneration else { return }
        encoders.removeAll(keepingCapacity: false)
    }

    private static func canonical(_ phrases: [String]) -> [String] {
        phrases.map {
            $0.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }.filter { !$0.isEmpty }
    }
}
