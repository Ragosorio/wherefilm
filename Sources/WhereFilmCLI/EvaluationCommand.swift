import Foundation
import ArgumentParser
import WhereFilmCore
import WhereFilmML
import WhereFilmSearch

/// `wherefilm eval` — how good is search, not how fast.
///
/// Runs an evaluation set through the real engine, in-process, and reports
/// recall, MRR, nDCG, the false-positive rate on negative cases and a
/// calibration table. Optionally diffs against a stored baseline, which is the
/// only honest way to claim that a change helped.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Measure search quality against a labelled set.",
        discussion: """
            Quality is measured on the REAL-MEDIA fixture only. The synthetic \
            bench-fixture catalog builds embeddings at a chosen cosine distance, \
            so it can measure latency and memory and nothing else — never recall.
            """)

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .long, help: "Evaluation set JSON.")
    var set: String = "Benchmarks/quality-v1.json"

    @Option(name: .shortAndLong, help: "How deep to rank before judging.")
    var limit: Int = 50

    @Option(name: .long, help: "MobileCLIP variant: s0, s1, s2, blt.")
    var model: String = "s0"

    @Flag(name: .long, help: "Skip the Apple on-device model even if it's available.")
    var noLLM = false

    @Flag(name: .long, help: "Skip the system translator (simulates a Mac without the language pack).")
    var noTranslation = false

    @Flag(name: .long, help: "Skip CLIP caption templates around each visual phrase.")
    var noTemplates = false

    @Option(name: .long, help: "Write the full report here as JSON.")
    var json: String?

    @Option(name: .long, help: "Compare against a report written by an earlier run.")
    var baseline: String?

    @Flag(name: .long, help: "Print one line per case.")
    var verbose = false

    @Option(name: .long, help: "Only run cases whose id or category contains this.")
    var filter: String?

    @Option(name: .long, help: "Ranking: rankFusion, confidence, blend.")
    var ranking: String = "confidence"

    @Option(name: .long, help: "Reciprocal rank fusion damping constant.")
    var rrfK: Double?

    @Option(name: .long, help: "Cosine similarity below which a visual hit is discarded.")
    var minVisual: Float?

    @Option(name: .long, help: "Drop results the engine itself rates below this (0–1).")
    var minConfidence: Double?

    @Flag(name: .long, help: "Judge visual hits by surprise (z-score) instead of raw cosine.")
    var surprise = false

    @Option(name: .long, help: "Standard deviations above the query mean below which a hit is noise.")
    var zFloor: Double?

    @Option(name: .long, help: "Standard deviations at which a visual hit is as good as it gets.")
    var zCeiling: Double?

    @Option(name: .long, help: "How rare a scene label must be to count as evidence (0 disables the channel).")
    var labelRarity: Double?

    @Option(name: .long, help: "Weight of the scene-label channel.")
    var labelWeight: Double?

    @Flag(name: .long, help: "Re-examine the survivors with a stronger model.")
    var rerank = false

    @Option(name: .long, help: "Which model does the second opinion: s0, s1, s2, blt.")
    var rerankModel: String = "s2"

    @Option(name: .long, help: "How many results the second pass re-examines.")
    var rerankDepth: Int?

    @Option(name: .long, help: "Cosine similarity treated as a perfect visual match.")
    var strongVisual: Float?

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'.")
        }
        let setURL = URL(fileURLWithPath: (set as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: setURL.path) else {
            throw ValidationError("No evaluation set at \(setURL.path)")
        }
        let evaluationSet = try EvaluationSet.load(contentsOf: setURL)
        let cases = evaluationSet.cases.filter { testCase in
            guard let filter else { return true }
            return testCase.id.localizedCaseInsensitiveContains(filter)
                || (testCase.category ?? "").localizedCaseInsensitiveContains(filter)
        }
        guard !cases.isEmpty else { throw ValidationError("No cases matched --filter.") }

        var options = SearchEngine.Options()
        options.limit = limit
        options.variant = variant
        guard let mode = SearchEngine.Ranking(rawValue: ranking) else {
            throw ValidationError("Unknown ranking '\(ranking)'. "
                + "Use one of: \(SearchEngine.Ranking.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        options.ranking = mode
        if let rrfK { options.weights.rrfK = rrfK }
        if let minVisual { options.weights.minimumVisualSimilarity = minVisual }
        if let minConfidence { options.minimumConfidence = minConfidence }
        options.weights.judgesVisualBySurprise = surprise
        if let zFloor { options.weights.visualZFloor = zFloor }
        if let zCeiling { options.weights.visualZCeiling = zCeiling }
        if let labelRarity { options.weights.minimumLabelRarity = labelRarity }
        if let labelWeight { options.weights.sceneLabel = labelWeight }
        options.rerank.isEnabled = rerank
        if let second = MobileCLIPVariant(rawValue: rerankModel) { options.rerank.variant = second }
        if let rerankDepth { options.rerank.depth = rerankDepth }
        if let strongVisual { options.weights.strongVisualSimilarity = strongVisual }
        let engine = SearchEngine(store: store, options: options)
        let planner = QueryPlanner(useFoundationModel: !noLLM,
                                   useSystemTranslation: !noTranslation,
                                   usesPromptTemplates: !noTemplates)
        let vectorIndex = try makeVectorIndex(variant: variant)
        try? await vectorIndex.openForSearch()

        let evaluator = Evaluator(defaultToleranceSeconds: evaluationSet.defaultToleranceSeconds)
        var outcomes: [CaseOutcome] = []
        var calibrationSamples: [(score: Double, relevant: Bool)] = []

        print("Evaluating \(cases.count) case\(cases.count == 1 ? "" : "s") from \(evaluationSet.name)")
        if let library = evaluationSet.library { print("Judgements written against: \(library)") }
        print("")

        for testCase in cases {
            let started = Date()
            let plan = await planner.plan(testCase.query)
            let results = try await engine.search(plan: plan, vectorIndex: vectorIndex)
            let elapsed = Date().timeIntervalSince(started) * 1_000

            let hits = results.map {
                EvaluatedHit(assetName: $0.displayName, startSeconds: $0.startSeconds,
                             endSeconds: $0.endSeconds, score: $0.score)
            }
            let outcome = evaluator.outcome(for: testCase, hits: hits, elapsedMilliseconds: elapsed)
            outcomes.append(outcome)
            calibrationSamples += evaluator.gradedSamples(for: testCase, hits: hits)

            if verbose {
                let mark = outcome.passed ? "✔" : "✘"
                let rank = outcome.firstRelevantRank.map { "#\($0)" }
                    ?? (outcome.isNegative ? "—" : "not found")
                print("  \(mark) \(outcome.id.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                    + "\(rank.padding(toLength: 11, withPad: " ", startingAt: 0)) "
                    + "\(outcome.returnedCount) result\(outcome.returnedCount == 1 ? "" : "s") · "
                    + String(format: "%.0f ms", outcome.elapsedMilliseconds)
                    + "   \(outcome.query)")
            }
        }
        if verbose { print("") }

        let report = EvaluationReport(
            setName: evaluationSet.name,
            library: evaluationSet.library,
            producedAt: Date(),
            configuration: "model=\(variant.rawValue) limit=\(limit) "
                + "ranking=\(mode.rawValue) k=\(Int(options.weights.rrfK)) "
                + "floor=\(minVisual.map { String($0) } ?? "model") "
                + "minConfidence=\(options.minimumConfidence) "
                + "rerank=\(rerank ? options.rerank.variant.rawValue : "off") "
                + "surprise=\(surprise ? "z\(options.weights.visualZFloor)–\(options.weights.visualZCeiling)" : "off") "
                + "ceiling=\(strongVisual.map { String($0) } ?? "model") "
                + "llm=\(noLLM ? "off" : (QueryPlanner.foundationModelAvailable ? "on" : "unavailable")) "
                + "translation=\(noTranslation ? "off" : "on") templates=\(noTemplates ? "off" : "on")",
            cases: outcomes,
            calibration: evaluator.calibration(from: calibrationSamples))

        printSummary(report)

        if let json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let url = URL(fileURLWithPath: (json as NSString).expandingTildeInPath)
            try encoder.encode(report).write(to: url)
            print("Report written to \(url.path)")
        }

        if let baseline {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let url = URL(fileURLWithPath: (baseline as NSString).expandingTildeInPath)
            let previous = try decoder.decode(EvaluationReport.self, from: Data(contentsOf: url))
            printDelta(EvaluationDelta(baseline: previous, current: report))
        }
    }

    private func printSummary(_ report: EvaluationReport) {
        let positives = report.positives.count
        print("Quality  (\(positives) positive · \(report.negatives.count) negative)")
        print("  answered at all   \(report.answeredCount)/\(positives)")
        print("  Recall@10         \(percent(report.recallAt10))")
        print("  Recall@50         \(percent(report.recallAt50))")
        print("  MRR               \(String(format: "%.3f", report.meanReciprocalRank))")
        print("  nDCG@10           \(String(format: "%.3f", report.ndcgAt10))")
        print("  false positives   \(percent(report.falsePositiveRate)) of negatives returned something")
        print("  median latency    \(String(format: "%.0f", report.medianMilliseconds)) ms")
        print("  configuration     \(report.configuration)")

        let unanswered = report.positives.filter { $0.firstRelevantRank == nil }
        if !unanswered.isEmpty {
            print("")
            print("Found nothing relevant (\(unanswered.count)):")
            for outcome in unanswered.prefix(15) {
                print("  · \(outcome.id) — \"\(outcome.query)\"")
            }
            if unanswered.count > 15 { print("  … and \(unanswered.count - 15) more") }
        }

        let noisy = report.negatives.filter(\.returnedWhenItShouldNot)
        if !noisy.isEmpty {
            print("")
            print("Answered when it should not have (\(noisy.count)):")
            for outcome in noisy {
                print("  · \(outcome.id) — \"\(outcome.query)\" returned \(outcome.returnedCount)")
            }
        }

        let calibration = report.calibration.filter { $0.hits > 0 }
        if !calibration.isEmpty {
            print("")
            print("Calibration — what the interface would show vs what was true")
            for bucket in calibration {
                let shown = Int(bucket.lowerBound * 100)
                let bar = String(repeating: "█", count: Int(bucket.observedPrecision * 20))
                print("  \(String(format: "%3d", shown))–\(String(format: "%3d", shown + 9))%  "
                    + "\(String(format: "%5d", bucket.hits)) hits  "
                    + "\(percent(bucket.observedPrecision)) actually relevant  \(bar)")
            }
        }
    }

    private func printDelta(_ delta: EvaluationDelta) {
        print("")
        print("Against baseline (\(delta.baseline.configuration))")
        print("  Recall@10   \(signed(delta.recallAt10Delta * 100)) points")
        print("  nDCG@10     \(signed(delta.ndcgAt10Delta))")
        print("  MRR         \(signed(delta.mrrDelta))")
        if delta.improvements.isEmpty && delta.regressions.isEmpty {
            print("  no case changed rank")
            return
        }
        if !delta.improvements.isEmpty {
            print("  improved (\(delta.improvements.count)):")
            for change in delta.improvements.prefix(10) {
                print("    ↑ \(change.id): \(rank(change.before)) → \(rank(change.after))")
            }
        }
        if !delta.regressions.isEmpty {
            print("  REGRESSED (\(delta.regressions.count)):")
            for change in delta.regressions {
                print("    ↓ \(change.id): \(rank(change.before)) → \(rank(change.after))  \"\(change.query)\"")
            }
        }
    }

    private func rank(_ value: Int?) -> String { value.map { "#\($0)" } ?? "not found" }
    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    private func signed(_ value: Double) -> String {
        String(format: value >= 0 ? "+%.3f" : "%.3f", value)
    }
}
