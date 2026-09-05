import Testing
import Foundation
@testable import WhereFilmSearch

@Suite("Search quality metrics")
struct EvaluationTests {
    private func hit(_ name: String, at seconds: Double = 0, score: Double = 0.5) -> EvaluatedHit {
        EvaluatedHit(assetName: name, startSeconds: seconds,
                     endSeconds: seconds + 5, score: score)
    }

    @Test("A judgement names a file, however the index spells its path")
    func assetNamesMatchByLastComponent() {
        #expect(Judge.sameAsset("INTERVIEW_JUAN_03.mov", "INTERVIEW_JUAN_03.mov"))
        #expect(Judge.sameAsset("interview_juan_03.MOV", "INTERVIEW_JUAN_03.mov"))
        #expect(Judge.sameAsset("Entrevistas/INTERVIEW_JUAN_03.mov", "INTERVIEW_JUAN_03.mov"))
        #expect(!Judge.sameAsset("INTERVIEW_JUAN_04.mov", "INTERVIEW_JUAN_03.mov"))
    }

    @Test("Three results on the same labelled moment are one success, not three")
    func recallCountsDistinctJudgements() {
        let testCase = EvaluationCase(
            id: "t", query: "q",
            relevant: [.init(asset: "A.mov", at: 100), .init(asset: "B.mov", at: 200)])
        // Three hits all landing on the first labelled moment.
        let hits = [hit("A.mov", at: 98), hit("A.mov", at: 101), hit("A.mov", at: 105)]
        let outcome = Evaluator().outcome(for: testCase, hits: hits, elapsedMilliseconds: 1)
        #expect(outcome.recallAt10 == 0.5)
        #expect(outcome.firstRelevantRank == 1)
    }

    @Test("A labelled instant inside a returned moment counts even beyond the tolerance")
    func instantInsideMomentCounts() {
        let testCase = EvaluationCase(
            id: "t", query: "q", relevant: [.init(asset: "A.mov", at: 300)])
        // The moment starts far from the label but contains it.
        let long = EvaluatedHit(assetName: "A.mov", startSeconds: 200, endSeconds: 400, score: 0.5)
        let outcome = Evaluator(defaultToleranceSeconds: 5)
            .outcome(for: testCase, hits: [long], elapsedMilliseconds: 1)
        #expect(outcome.firstRelevantRank == 1)
    }

    @Test("A result far from the labelled instant does not count")
    func farMomentDoesNotCount() {
        let testCase = EvaluationCase(
            id: "t", query: "q", relevant: [.init(asset: "A.mov", at: 300)])
        let outcome = Evaluator(defaultToleranceSeconds: 30)
            .outcome(for: testCase, hits: [hit("A.mov", at: 10)], elapsedMilliseconds: 1)
        #expect(outcome.firstRelevantRank == nil)
        #expect(outcome.recallAt10 == 0)
    }

    @Test("A negative case passes only when nothing comes back")
    func negativesInvertTheTest() {
        let negative = EvaluationCase(id: "n", query: "un plato de espagueti", expectation: .empty)
        let quiet = Evaluator().outcome(for: negative, hits: [], elapsedMilliseconds: 1)
        #expect(quiet.passed)
        #expect(!quiet.returnedWhenItShouldNot)

        let noisy = Evaluator().outcome(for: negative, hits: [hit("BEACH.heic")],
                                        elapsedMilliseconds: 1)
        #expect(!noisy.passed)
        #expect(noisy.returnedWhenItShouldNot)
    }

    @Test("nDCG rewards putting the best answer first")
    func ndcgRewardsOrdering() {
        let judgements: [EvaluationCase.RelevantMoment] = [
            .init(asset: "best.heic", grade: 3), .init(asset: "ok.heic", grade: 1),
        ]
        let ideal = Evaluator.ndcg(grades: [3, 1], judgements: judgements, cutoff: 10)
        let reversed = Evaluator.ndcg(grades: [1, 3], judgements: judgements, cutoff: 10)
        let missed = Evaluator.ndcg(grades: [0, 0], judgements: judgements, cutoff: 10)
        #expect(ideal == 1.0)
        #expect(reversed < ideal)
        #expect(missed == 0)
    }

    @Test("The legacy Spanish fixture loads unchanged and gains metrics")
    func legacyFixtureStillLoads() throws {
        // The twelve cases written for the latency benchmark used only
        // `expectedAssets`. Reading them here is what proves the richer format
        // is a superset rather than a replacement.
        let json = """
        {"name":"legacy","cases":[
          {"id":"sunset-neutral","category":"neutral Spanish","cluster":"sunset",
           "query":"atardecer frente al mar","expectedAssets":["SUNSET_0005.heic"]}]}
        """
        let set = try JSONDecoder().decode(EvaluationSet.self, from: Data(json.utf8))
        #expect(set.cases.count == 1)
        #expect(set.cases[0].judgements.count == 1)
        #expect(set.cases[0].judgements[0].grade == 1)
        #expect(!set.cases[0].isNegative)

        let outcome = Evaluator().outcome(
            for: set.cases[0], hits: [hit("SUNSET_0005.heic")], elapsedMilliseconds: 1)
        #expect(outcome.recallAt10 == 1)
    }

    @Test("Calibration buckets say what a displayed percentage was actually worth")
    func calibrationBuckets() {
        let buckets = Evaluator().calibration(from: [
            (0.95, true), (0.92, true), (0.91, false),
            (0.15, false), (0.11, false),
        ])
        let high = try? #require(buckets.first { $0.lowerBound == 0.9 })
        #expect(high?.hits == 3)
        #expect(high?.relevant == 2)
        let low = buckets.first { $0.lowerBound == 0.1 }
        #expect(low?.observedPrecision == 0)
    }

    @Test("A delta names the cases that got worse")
    func deltaFindsRegressions() {
        func report(_ ranks: [String: Int?]) -> EvaluationReport {
            EvaluationReport(
                setName: "s", library: nil, producedAt: Date(), configuration: "c",
                cases: ranks.map { id, rank in
                    CaseOutcome(id: id, query: id, isNegative: false, firstRelevantRank: rank,
                                recallAt10: rank == nil ? 0 : 1, recallAt50: rank == nil ? 0 : 1,
                                ndcgAt10: rank == nil ? 0 : 1,
                                reciprocalRank: rank.map { 1 / Double($0) } ?? 0,
                                returnedWhenItShouldNot: false, returnedCount: 1,
                                elapsedMilliseconds: 1)
                },
                calibration: [])
        }
        let delta = EvaluationDelta(baseline: report(["a": 1, "b": 5, "c": 2]),
                                   current: report(["a": 1, "b": 2, "c": nil]))
        #expect(delta.improvements.map(\.id) == ["b"])
        #expect(delta.regressions.map(\.id) == ["c"])
    }
}
