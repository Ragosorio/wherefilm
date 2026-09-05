import Foundation

/// Measuring whether search is *good*, as opposed to whether it is *fast*.
///
/// The project could already measure latency, and did so carefully — the scale
/// pass proved a nine-vector fixture reported 1.78 ms for work that costs
/// 1,472 ms on a real library. But nothing here could measure **recall**, and
/// that is the number the product actually lives or dies by: "it returns the
/// right things, but it doesn't work" is a recall complaint, not a speed one.
///
/// So this file is deliberately the first thing built in the precision pass. It
/// has no opinion about how search works; it takes a ranked list and a set of
/// human judgements and produces numbers that can be compared across builds.
///
/// **Hard rule, inherited from the scale pass:** these metrics are only
/// meaningful over the *real-media* fixture. The synthetic `bench-fixture`
/// catalog constructs embeddings at a chosen cosine distance, so it can measure
/// latency, memory and scaling and nothing else. Never quote recall from it.

// MARK: - The dataset

/// One evaluation set on disk.
///
/// The format is a strict superset of `Benchmarks/spanish-search-v1.json`, so
/// the twelve cases that already existed load unchanged and immediately gain
/// MRR and nDCG they never had.
public struct EvaluationSet: Decodable, Sendable {
    public var name: String
    /// Which library these judgements were written against. Purely advisory, but
    /// a mismatch is the single most common way an evaluation quietly lies.
    public var library: String?
    /// How close in seconds a result must land to a labelled instant to count.
    /// A moment is an interval, and people label the instant they remember.
    public var defaultToleranceSeconds: Double
    public var cases: [EvaluationCase]

    enum CodingKeys: String, CodingKey {
        case name, library, defaultToleranceSeconds, cases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "unnamed set"
        library = try container.decodeIfPresent(String.self, forKey: .library)
        defaultToleranceSeconds =
            try container.decodeIfPresent(Double.self, forKey: .defaultToleranceSeconds) ?? 30
        cases = try container.decode([EvaluationCase].self, forKey: .cases)
    }

    public init(name: String, library: String? = nil,
                defaultToleranceSeconds: Double = 30, cases: [EvaluationCase]) {
        self.name = name
        self.library = library
        self.defaultToleranceSeconds = defaultToleranceSeconds
        self.cases = cases
    }

    public static func load(contentsOf url: URL) throws -> EvaluationSet {
        try JSONDecoder().decode(EvaluationSet.self, from: Data(contentsOf: url))
    }
}

public struct EvaluationCase: Decodable, Sendable {
    public var id: String
    public var query: String
    public var category: String?
    public var cluster: String?
    public var language: String?
    /// Asset-level relevance — the original, simplest form.
    public var expectedAssets: [String]
    /// Moment-level relevance with grades. Richer, and what nDCG needs to say
    /// anything interesting.
    public var relevant: [RelevantMoment]
    /// A negative case: the correct answer is *nothing*. A search tool that
    /// answers "un plato de espagueti" with the least-bad landscape teaches
    /// people to distrust every number it prints.
    public var expectation: Expectation

    public enum Expectation: String, Decodable, Sendable {
        case any
        case empty
    }

    public struct RelevantMoment: Decodable, Sendable {
        /// File name as the index displays it. Compared case-insensitively.
        public var asset: String
        /// Seconds into the asset. `nil` means "anywhere in this file".
        public var at: Double?
        /// Graded relevance: 3 perfect, 2 good, 1 acceptable. Defaults to 1.
        public var grade: Int
        /// Per-item override of the set's tolerance.
        public var toleranceSeconds: Double?

        enum CodingKeys: String, CodingKey { case asset, at, grade, toleranceSeconds }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            asset = try container.decode(String.self, forKey: .asset)
            at = try container.decodeIfPresent(Double.self, forKey: .at)
            grade = try container.decodeIfPresent(Int.self, forKey: .grade) ?? 1
            toleranceSeconds = try container.decodeIfPresent(Double.self, forKey: .toleranceSeconds)
        }

        public init(asset: String, at: Double? = nil, grade: Int = 1,
                    toleranceSeconds: Double? = nil) {
            self.asset = asset
            self.at = at
            self.grade = grade
            self.toleranceSeconds = toleranceSeconds
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, query, category, cluster, lang, language
        case expectedAssets, relevant, expect, expectation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        query = try container.decode(String.self, forKey: .query)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        cluster = try container.decodeIfPresent(String.self, forKey: .cluster)
        language = try container.decodeIfPresent(String.self, forKey: .lang)
            ?? container.decodeIfPresent(String.self, forKey: .language)
        expectedAssets = try container.decodeIfPresent([String].self, forKey: .expectedAssets) ?? []
        relevant = try container.decodeIfPresent([RelevantMoment].self, forKey: .relevant) ?? []
        expectation = try container.decodeIfPresent(Expectation.self, forKey: .expect)
            ?? container.decodeIfPresent(Expectation.self, forKey: .expectation)
            ?? .any
    }

    public init(id: String, query: String, category: String? = nil, cluster: String? = nil,
                language: String? = nil, expectedAssets: [String] = [],
                relevant: [RelevantMoment] = [], expectation: Expectation = .any) {
        self.id = id
        self.query = query
        self.category = category
        self.cluster = cluster
        self.language = language
        self.expectedAssets = expectedAssets
        self.relevant = relevant
        self.expectation = expectation
    }

    /// Every distinct thing that would count as a correct answer. Asset-level
    /// entries are folded in as moments with no instant, so both forms are
    /// judged by one code path.
    public var judgements: [RelevantMoment] {
        var all = relevant
        for asset in expectedAssets
        where !relevant.contains(where: { $0.asset.caseInsensitiveCompare(asset) == .orderedSame }) {
            all.append(RelevantMoment(asset: asset))
        }
        return all
    }

    public var isNegative: Bool { expectation == .empty }
}

// MARK: - What a search returned, reduced to what judging needs

/// Deliberately not `SearchResult`. Judging needs three fields, and depending on
/// the whole result type would make the metrics impossible to unit-test without
/// a database, previews and a volume registry.
public struct EvaluatedHit: Sendable {
    public let assetName: String
    public let startSeconds: Double
    public let endSeconds: Double
    /// The 0–1 confidence the interface would display.
    public let score: Double

    public init(assetName: String, startSeconds: Double, endSeconds: Double, score: Double) {
        self.assetName = assetName
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.score = score
    }
}

// MARK: - Judging

public enum Judge {
    /// The graded relevance of one hit, and which judgement it satisfied.
    ///
    /// Returning the index matters: recall counts *distinct labelled moments
    /// found*, so three results landing on the same labelled instant are one
    /// success, not three.
    static func grade(hit: EvaluatedHit, against judgements: [EvaluationCase.RelevantMoment],
                      defaultTolerance: Double) -> (grade: Int, index: Int)? {
        var best: (grade: Int, index: Int)?
        for (index, judgement) in judgements.enumerated() {
            guard sameAsset(hit.assetName, judgement.asset) else { continue }
            if let instant = judgement.at {
                let tolerance = judgement.toleranceSeconds ?? defaultTolerance
                // Either the labelled instant falls inside the returned moment,
                // or the moment starts close enough to it. A moment is a range;
                // a person labels a point inside the range they remember.
                let inside = instant >= hit.startSeconds && instant <= max(hit.endSeconds, hit.startSeconds)
                let near = abs(hit.startSeconds - instant) <= tolerance
                guard inside || near else { continue }
            }
            if best == nil || judgement.grade > best!.grade {
                best = (judgement.grade, index)
            }
        }
        return best
    }

    /// File names, compared the way a person writing judgements would expect:
    /// case-insensitively, and by last path component so a judgement can name
    /// `INTERVIEW_JUAN_03.mov` or `Entrevistas/INTERVIEW_JUAN_03.mov`.
    static func sameAsset(_ a: String, _ b: String) -> Bool {
        let left = (a as NSString).lastPathComponent
        let right = (b as NSString).lastPathComponent
        return left.caseInsensitiveCompare(right) == .orderedSame
    }
}

// MARK: - Metrics

public struct CaseOutcome: Codable, Sendable {
    public var id: String
    public var query: String
    public var category: String?
    public var language: String?
    public var isNegative: Bool
    /// Rank (1-based) of the first relevant hit, if any.
    public var firstRelevantRank: Int?
    public var recallAt10: Double
    public var recallAt50: Double
    public var ndcgAt10: Double
    public var reciprocalRank: Double
    /// Negatives only: did anything come back when nothing should have?
    public var returnedWhenItShouldNot: Bool
    public var returnedCount: Int
    public var elapsedMilliseconds: Double

    public var passed: Bool {
        isNegative ? !returnedWhenItShouldNot : firstRelevantRank != nil
    }

    public init(id: String, query: String, category: String? = nil, language: String? = nil,
                isNegative: Bool, firstRelevantRank: Int?, recallAt10: Double,
                recallAt50: Double, ndcgAt10: Double, reciprocalRank: Double,
                returnedWhenItShouldNot: Bool, returnedCount: Int,
                elapsedMilliseconds: Double) {
        self.id = id
        self.query = query
        self.category = category
        self.language = language
        self.isNegative = isNegative
        self.firstRelevantRank = firstRelevantRank
        self.recallAt10 = recallAt10
        self.recallAt50 = recallAt50
        self.ndcgAt10 = ndcgAt10
        self.reciprocalRank = reciprocalRank
        self.returnedWhenItShouldNot = returnedWhenItShouldNot
        self.returnedCount = returnedCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct CalibrationBucket: Codable, Sendable {
    /// Lower edge of the displayed-confidence bucket, e.g. 0.6 for 60–69%.
    public var lowerBound: Double
    public var hits: Int
    public var relevant: Int

    public var observedPrecision: Double {
        hits == 0 ? 0 : Double(relevant) / Double(hits)
    }

    public init(lowerBound: Double, hits: Int, relevant: Int) {
        self.lowerBound = lowerBound
        self.hits = hits
        self.relevant = relevant
    }
}

/// Everything one evaluation run produced. `Codable` on purpose: a run is only
/// useful next to the run before it, and diffing JSON is how a change proves it
/// helped rather than merely felt better.
public struct EvaluationReport: Codable, Sendable {
    public var setName: String
    public var library: String?
    public var producedAt: Date
    /// Free-form description of the configuration under test, so a report file
    /// says what it was measuring.
    public var configuration: String
    public var cases: [CaseOutcome]
    public var calibration: [CalibrationBucket]

    public init(setName: String, library: String?, producedAt: Date, configuration: String,
                cases: [CaseOutcome], calibration: [CalibrationBucket]) {
        self.setName = setName
        self.library = library
        self.producedAt = producedAt
        self.configuration = configuration
        self.cases = cases
        self.calibration = calibration
    }

    public var positives: [CaseOutcome] { cases.filter { !$0.isNegative } }
    public var negatives: [CaseOutcome] { cases.filter(\.isNegative) }

    public var recallAt10: Double { mean(positives.map(\.recallAt10)) }
    public var recallAt50: Double { mean(positives.map(\.recallAt50)) }
    public var ndcgAt10: Double { mean(positives.map(\.ndcgAt10)) }
    public var meanReciprocalRank: Double { mean(positives.map(\.reciprocalRank)) }
    /// Fraction of negative cases that wrongly returned something.
    public var falsePositiveRate: Double {
        negatives.isEmpty ? 0 : mean(negatives.map { $0.returnedWhenItShouldNot ? 1 : 0 })
    }
    public var answeredCount: Int { positives.filter { $0.firstRelevantRank != nil }.count }
    public var medianMilliseconds: Double {
        let sorted = cases.map(\.elapsedMilliseconds).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// Turns ranked results into metrics. Pure, synchronous and dependency-free, so
/// every number below is unit-testable without touching a database.
public struct Evaluator: Sendable {
    public var defaultToleranceSeconds: Double

    public init(defaultToleranceSeconds: Double = 30) {
        self.defaultToleranceSeconds = defaultToleranceSeconds
    }

    public func outcome(for testCase: EvaluationCase, hits: [EvaluatedHit],
                        elapsedMilliseconds: Double) -> CaseOutcome {
        let judgements = testCase.judgements

        // Graded relevance per rank, plus which labelled moment each hit found.
        var grades: [Int] = []
        var foundIndexes: Set<Int> = []
        var foundAtRank: [Int: Int] = [:]      // judgement index → best (lowest) rank
        for (rank, hit) in hits.enumerated() {
            guard let match = Judge.grade(hit: hit, against: judgements,
                                          defaultTolerance: defaultToleranceSeconds) else {
                grades.append(0)
                continue
            }
            grades.append(match.grade)
            foundIndexes.insert(match.index)
            if foundAtRank[match.index] == nil { foundAtRank[match.index] = rank + 1 }
        }

        let firstRelevantRank = grades.firstIndex(where: { $0 > 0 }).map { $0 + 1 }
        let total = max(judgements.count, 1)

        func recall(cutoff: Int) -> Double {
            guard !judgements.isEmpty else { return 0 }
            let found = foundAtRank.values.filter { $0 <= cutoff }.count
            return Double(found) / Double(total)
        }

        return CaseOutcome(
            id: testCase.id,
            query: testCase.query,
            category: testCase.category,
            language: testCase.language,
            isNegative: testCase.isNegative,
            firstRelevantRank: firstRelevantRank,
            recallAt10: recall(cutoff: 10),
            recallAt50: recall(cutoff: 50),
            ndcgAt10: Self.ndcg(grades: grades, judgements: judgements, cutoff: 10),
            reciprocalRank: firstRelevantRank.map { 1 / Double($0) } ?? 0,
            returnedWhenItShouldNot: testCase.isNegative && !hits.isEmpty,
            returnedCount: hits.count,
            elapsedMilliseconds: elapsedMilliseconds)
    }

    /// Normalised discounted cumulative gain.
    ///
    /// Recall asks "did it find them?"; nDCG asks "did it put the best one
    /// first?". Both matter here for different reasons: recall is the complaint
    /// ("it doesn't find it"), nDCG is the experience ("it finds it at number
    /// nine, under three wrong answers").
    static func ndcg(grades: [Int], judgements: [EvaluationCase.RelevantMoment],
                     cutoff: Int) -> Double {
        guard !judgements.isEmpty else { return 0 }
        func dcg(_ values: [Int]) -> Double {
            values.prefix(cutoff).enumerated().reduce(0.0) { sum, entry in
                let (index, grade) = entry
                guard grade > 0 else { return sum }
                return sum + (pow(2, Double(grade)) - 1) / log2(Double(index + 2))
            }
        }
        let ideal = dcg(judgements.map(\.grade).sorted(by: >))
        guard ideal > 0 else { return 0 }
        return dcg(grades) / ideal
    }

    /// Buckets displayed confidence against observed correctness.
    ///
    /// This is the number nobody asks for and everybody needs. A tool that shows
    /// 94% on results that are right half the time has not got a ranking problem
    /// — it has a *trust* problem, and no amount of recall fixes it.
    public func calibration(from samples: [(score: Double, relevant: Bool)]) -> [CalibrationBucket] {
        var buckets: [Int: CalibrationBucket] = [:]
        for sample in samples {
            let index = min(9, max(0, Int(sample.score * 10)))
            var bucket = buckets[index]
                ?? CalibrationBucket(lowerBound: Double(index) / 10, hits: 0, relevant: 0)
            bucket.hits += 1
            if sample.relevant { bucket.relevant += 1 }
            buckets[index] = bucket
        }
        return buckets.values.sorted { $0.lowerBound < $1.lowerBound }
    }

    public func gradedSamples(for testCase: EvaluationCase,
                              hits: [EvaluatedHit]) -> [(score: Double, relevant: Bool)] {
        let judgements = testCase.judgements
        return hits.map { hit in
            let relevant = Judge.grade(hit: hit, against: judgements,
                                       defaultTolerance: defaultToleranceSeconds) != nil
            return (hit.score, relevant)
        }
    }
}

// MARK: - Comparing two runs

/// The delta between a baseline report and a new one.
///
/// Every phase of the precision work is required to state its effect as a delta
/// against a stored baseline. Without this, "it feels better" is the whole
/// quality process.
public struct EvaluationDelta: Sendable {
    public struct Change: Sendable {
        public let id: String
        public let query: String
        public let before: Int?
        public let after: Int?

        public var isRegression: Bool {
            switch (before, after) {
            case (.some, .none): true
            case let (.some(a), .some(b)): b > a
            default: false
            }
        }
        public var isImprovement: Bool {
            switch (before, after) {
            case (.none, .some): true
            case let (.some(a), .some(b)): b < a
            default: false
            }
        }
    }

    public let baseline: EvaluationReport
    public let current: EvaluationReport
    public let changes: [Change]

    public init(baseline: EvaluationReport, current: EvaluationReport) {
        self.baseline = baseline
        self.current = current
        let before = Dictionary(uniqueKeysWithValues: baseline.cases.map { ($0.id, $0) })
        self.changes = current.cases.compactMap { outcome in
            guard let previous = before[outcome.id] else { return nil }
            guard previous.firstRelevantRank != outcome.firstRelevantRank else { return nil }
            return Change(id: outcome.id, query: outcome.query,
                          before: previous.firstRelevantRank, after: outcome.firstRelevantRank)
        }
    }

    public var regressions: [Change] { changes.filter(\.isRegression) }
    public var improvements: [Change] { changes.filter(\.isImprovement) }
    public var recallAt10Delta: Double { current.recallAt10 - baseline.recallAt10 }
    public var ndcgAt10Delta: Double { current.ndcgAt10 - baseline.ndcgAt10 }
    public var mrrDelta: Double { current.meanReciprocalRank - baseline.meanReciprocalRank }
}
