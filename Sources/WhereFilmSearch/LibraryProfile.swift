import Foundation
import Accelerate
import WhereFilmCore

/// What this library looks like to a query, so "similar" can be judged against
/// something.
///
/// A fixed cosine floor assumes every query starts from the same place. CLIP
/// does not work that way: some text vectors sit closer to every image than
/// others do, so a floor calibrated on "atardecer frente al mar" is the wrong
/// floor for "un plato de espagueti" — the second resembles nothing in
/// particular, but it resembles *everything* a little, and a fixed threshold
/// lets it through with confidence.
///
/// The fix is to stop asking "how similar is this?" and start asking "how
/// unusual is this similarity, for this query?". That needs the shape of the
/// query's similarity distribution over the library, which is one pass over a
/// small sample: a thousand vectors, kept in memory, ~2 MB.
actor LibraryProfile {
    static let shared = LibraryProfile()

    /// Mean and spread of one query's similarity to the whole library.
    struct Statistics: Sendable {
        let mean: Double
        let standardDeviation: Double

        /// How many standard deviations above the library's average similarity
        /// a given cosine sits. This is the number the floor should have been
        /// written in all along.
        func zScore(_ similarity: Float) -> Double {
            (Double(similarity) - mean) / max(standardDeviation, 1e-6)
        }
    }

    private struct Sample {
        /// Flattened, so the whole thing is one contiguous buffer for vDSP.
        let values: [Float]
        let dimensions: Int
        let count: Int
        let countWhenSampled: Int
    }
    private var samples: [String: Sample] = [:]

    func statistics(store: IndexStore, modelID: String, query: [Float]) -> Statistics? {
        guard let sample = sample(store: store, modelID: modelID),
              sample.dimensions == query.count, sample.count > 1 else { return nil }

        var similarities = [Float](repeating: 0, count: sample.count)
        sample.values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<sample.count {
                var dot: Float = 0
                vDSP_dotpr(base + index * sample.dimensions, 1, query, 1,
                           &dot, vDSP_Length(sample.dimensions))
                similarities[index] = dot
            }
        }

        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(similarities, 1, nil, 1, &mean, &deviation,
                       vDSP_Length(similarities.count))
        return Statistics(mean: Double(mean), standardDeviation: Double(deviation))
    }

    private func sample(store: IndexStore, modelID: String) -> Sample? {
        let total = (try? store.embeddingCount(modelID: modelID)) ?? 0
        guard total > 0 else { return nil }
        if let existing = samples[modelID] {
            // The distribution barely moves as a library grows; resampling on
            // every search would cost more than it could possibly correct.
            let drift = abs(total - existing.countWhenSampled)
            if Double(drift) < Double(existing.countWhenSampled) * 0.2 { return existing }
        }
        guard let vectors = try? store.embeddingSample(modelID: modelID),
              let dimensions = vectors.first?.count, dimensions > 0 else {
            return samples[modelID]
        }
        let usable = vectors.filter { $0.count == dimensions }
        guard usable.count > 1 else { return samples[modelID] }
        let sample = Sample(values: usable.flatMap { $0 }, dimensions: dimensions,
                            count: usable.count, countWhenSampled: total)
        samples[modelID] = sample
        return sample
    }

    /// Test seam, and how a rebuild drops state that no longer describes
    /// anything.
    func forget(modelID: String? = nil) {
        if let modelID { samples[modelID] = nil } else { samples.removeAll() }
    }
}
