import Foundation
import ArgumentParser
import CoreGraphics
import ImageIO
import WhereFilmCore
import WhereFilmML
import WhereFilmSearch

/// `wherefilm calibrate` — what a similarity score is worth, for one model.
///
/// `MobileCLIPVariant.similarityFloor` and `similarityCeiling` decide what may
/// enter a ranking and what reads as a perfect match. They were measured once,
/// for S0, and the type says plainly that swapping models has to swap them too.
/// Nothing enforced that, and the cost showed up immediately: reranking with S2
/// judged by S0's numbers made results *worse* — nDCG 0.855 → 0.840 — which is
/// what a better model looks like when it is scored on somebody else's scale.
///
/// So this measures the scale instead of assuming it. It runs an evaluation set
/// against the previews already on disk, separates similarities of *relevant*
/// answers from everything else, and reports the two numbers that separate them.
struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Measure what a model's similarity scores are worth on this library.",
        discussion: """
            Quality-grade measurement: run it against the real-media library, \
            never against bench-fixture. It reads preview thumbnails rather than \
            reopening originals, so it costs one batch of image encodes.
            """)

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .long, help: "Evaluation set JSON.")
    var set: String = "Benchmarks/quality-v1.json"

    @Option(name: .long, help: "Which model to calibrate: s0, s1, s2, blt.")
    var model: String = "s2"

    @Option(name: .long, help: "How many moments to score per query.")
    var depth = 60

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'.")
        }
        let setURL = URL(fileURLWithPath: (set as NSString).expandingTildeInPath)
        let evaluationSet = try EvaluationSet.load(contentsOf: setURL)

        // Every moment that has a preview, encoded once with the model under
        // test. The library is the same for every query, so this is paid once.
        let moments = try store.allMomentsWithPreviews(limit: 5000)
        guard !moments.isEmpty else {
            throw ValidationError("No previews on disk — index a library first.")
        }
        print("Encoding \(moments.count) preview thumbnails with \(variant.modelID)…")

        let encoder = try MobileCLIPImageEncoder(variant: variant)
        var vectors: [Int64: [Float]] = [:]
        var assetOf: [Int64: Int64] = [:]
        var startOf: [Int64: Double] = [:]
        var endOf: [Int64: Double] = [:]
        var batchIDs: [Int64] = []
        var batchImages: [CGImage] = []

        func flush() throws {
            guard !batchImages.isEmpty else { return }
            let encoded = try encoder.encode(batch: batchImages)
            for (index, momentID) in batchIDs.enumerated() where index < encoded.count {
                vectors[momentID] = encoded[index]
            }
            batchIDs.removeAll(keepingCapacity: true)
            batchImages.removeAll(keepingCapacity: true)
        }

        for moment in moments {
            guard let image = SearchEngine.loadImage(atPath: moment.previewPath) else { continue }
            assetOf[moment.momentID] = moment.assetID
            startOf[moment.momentID] = moment.startSeconds
            endOf[moment.momentID] = moment.endSeconds
            batchIDs.append(moment.momentID)
            batchImages.append(image)
            if batchImages.count >= 8 { try flush() }
        }
        try flush()
        print("Encoded \(vectors.count).\n")

        let names = try store.assets(ids: Array(Set(assetOf.values)))
        let evaluator = Evaluator(defaultToleranceSeconds: evaluationSet.defaultToleranceSeconds)
        var relevant: [Double] = []
        var irrelevant: [Double] = []
        var negativeBest: [Double] = []

        for testCase in evaluationSet.cases {
            // Deterministic on purpose: calibration is a measurement, and the
            // on-device planner answers differently on identical runs.
            let plan = await QueryPlanner(useFoundationModel: false,
                                          useSystemTranslation: true).plan(testCase.query)
            guard plan.hasVisualSignal else { continue }
            let text = try MobileCLIPTextEncoder(variant: variant)
            guard let query = try? text.encodeEnsemble(plan.visualPhrases), !query.isEmpty
            else { continue }

            var scored: [(momentID: Int64, similarity: Double)] = vectors.map {
                ($0.key, Double(VectorCodec.dot(query, $0.value)))
            }
            scored.sort { $0.similarity > $1.similarity }

            if testCase.isNegative {
                // The best score a query with no right answer can reach is the
                // number the floor has to sit above.
                if let best = scored.first { negativeBest.append(best.similarity) }
                continue
            }

            for entry in scored.prefix(depth) {
                guard let assetID = assetOf[entry.momentID],
                      let name = names[assetID]?.displayName else { continue }
                let hit = EvaluatedHit(assetName: name,
                                       startSeconds: startOf[entry.momentID] ?? 0,
                                       endSeconds: endOf[entry.momentID] ?? 0,
                                       score: 0)
                let isRelevant = evaluator.gradedSamples(for: testCase, hits: [hit])
                    .first?.relevant ?? false
                if isRelevant { relevant.append(entry.similarity) }
                else { irrelevant.append(entry.similarity) }
            }
        }

        guard !relevant.isEmpty, !irrelevant.isEmpty else {
            throw ValidationError("Not enough judged results to calibrate.")
        }

        func percentile(_ fraction: Double, _ values: [Double]) -> Double {
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded())
            return sorted[max(0, min(sorted.count - 1, index))]
        }

        print("Similarity of \(relevant.count) relevant vs \(irrelevant.count) irrelevant results")
        print("  relevant    p05 \(f(percentile(0.05, relevant)))  p50 \(f(percentile(0.5, relevant)))  p95 \(f(percentile(0.95, relevant)))")
        print("  irrelevant  p50 \(f(percentile(0.5, irrelevant)))  p95 \(f(percentile(0.95, irrelevant)))  max \(f(irrelevant.max() ?? 0))")
        if !negativeBest.isEmpty {
            print("  best score reached by a query with no right answer: \(f(negativeBest.max() ?? 0))")
        }

        // A floor is a trade, not a fact, so this reports the trade.
        //
        // The obvious formula — "sit above the worst wrong answer" — is wrong,
        // and measurably: one adversarial negative reaching 0.256 would set a
        // floor that discards most of the right answers too. What matters is
        // where the two distributions separate *best*, and how much they overlap
        // at that point.
        var best = (threshold: 0.0, f1: 0.0, kept: 0, admitted: 0)
        var candidates: [Double] = []
        var value = 0.05
        while value <= 0.40 { candidates.append(value); value += 0.005 }
        for threshold in candidates {
            let kept = relevant.filter { $0 >= threshold }.count
            let admitted = irrelevant.filter { $0 >= threshold }.count
            guard kept > 0 else { continue }
            let precision = Double(kept) / Double(kept + admitted)
            let recall = Double(kept) / Double(relevant.count)
            let f1 = 2 * precision * recall / (precision + recall)
            if f1 > best.f1 { best = (threshold, f1, kept, admitted) }
        }

        let ceiling = percentile(0.9, relevant)
        let separation = percentile(0.5, relevant) - percentile(0.5, irrelevant)
        print("\nSeparation between right and wrong answers: \(f(separation)) at the median")
        print("Best single threshold: \(f(best.threshold)) — keeps "
            + "\(best.kept)/\(relevant.count) relevant, admits \(best.admitted) irrelevant "
            + "(F1 \(f(best.f1)))")
        print("\nSuggested for \(variant.modelID):")
        print("  similarityFloor   \(f(best.threshold))     (currently \(f(Double(variant.similarityFloor))))")
        print("  similarityCeiling \(f(ceiling))     (currently \(f(Double(variant.similarityCeiling))))")

        if best.f1 < 0.5 {
            print("\n  ⚠ The distributions overlap heavily. On this library the model")
            print("    cannot separate right from wrong with any single threshold, and")
            print("    no pair of constants will fix that — which is worth knowing")
            print("    before blaming the ranking for it.")
        }
    }

    private func f(_ value: Double) -> String { String(format: "%.3f", value) }
}
