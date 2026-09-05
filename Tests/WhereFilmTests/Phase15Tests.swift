import Foundation
import Testing
import GRDB
import Darwin
@testable import WhereFilmCore
@testable import WhereFilmML
@testable import WhereFilmIndex
@testable import WhereFilmSearch

private func phase15Store() throws -> IndexStore {
    try IndexStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("wf-phase15-" + UUID().uuidString).appendingPathComponent("index.sqlite"))
}

private func usageSamples(_ store: IndexStore, preferred: String = "transcript", count: Int = 100) throws {
    try store.setUsageLearningEnabled(true)
    for i in 0..<count {
        try store.record(action: .open, query: "query \(i)", channels: [preferred, preferred, "invalid"])
        try store.record(action: .reformulate, query: "query \(i)", channels: [preferred == "ocr" ? "transcript" : "ocr"])
    }
}

@Suite("Local learning safeguards")
struct UsageTests {
    @Test("Disabled by default; hashes are stable within one catalog and isolated across catalogs")
    func privateHash() throws {
        let store = try phase15Store()
        try store.record(action: .open, query: "Jorge Álvarez", channels: ["person"])
        #expect(try store.interactionCount() == 0)
        try store.setUsageLearningEnabled(true)
        try store.record(action: .open, query: "Jorge Álvarez", channels: ["person"])
        let reopened = try IndexStore(url: URL(fileURLWithPath: store.dbPool.path))
        try reopened.record(action: .open, query: "  JORGE   ALVAREZ ", channels: ["person"])
        let hashes = try store.dbPool.read { try String.fetchAll($0, sql: "SELECT queryHash FROM interactions ORDER BY id") }
        #expect(hashes.count == 2 && hashes[0] == hashes[1] && hashes[0].count == 64)
        let other = try phase15Store()
        try other.setUsageLearningEnabled(true)
        try other.record(action: .open, query: "Jorge Álvarez", channels: ["person"])
        let otherHash = try other.dbPool.read { try String.fetchOne($0, sql: "SELECT queryHash FROM interactions") }
        #expect(otherHash != hashes[0])
        let export = String(decoding: try JSONEncoder().encode(store.usageReport()), as: UTF8.self)
        #expect(!export.contains("queryHash") && !export.contains("Jorge") && !export.contains("queryKey"))
    }

    @Test("Warmup, conservative shifts and immediate cache invalidation including another library")
    func cacheAndReset() async throws {
        let store = try phase15Store()
        try usageSamples(store, count: 99)
        #expect(try store.channelPreferences().isEmpty)
        try usageSamples(store, count: 1)
        let first = await LearnedWeights.shared.preferences(store: store)
        #expect(first["transcript"]!.multiplier > 1)
        #expect(first["ocr"]!.multiplier < 1)
        #expect(first.values.allSatisfy { (0.85...1.15).contains($0.multiplier) })
        #expect(first.count == 2)
        let other = try phase15Store()
        #expect(await LearnedWeights.shared.preferences(store: other).isEmpty)
        #expect(!(await LearnedWeights.shared.preferences(store: store)).isEmpty)
        try store.forgetUsage()
        #expect(await LearnedWeights.shared.preferences(store: store).isEmpty)
        #expect(try store.interactionCount() == 0)
        try usageSamples(store)
        try store.setUsageLearningEnabled(false)
        #expect(await LearnedWeights.shared.preferences(store: store).isEmpty)
    }

    @Test("Personalization changes order, never membership or confidence, in all search entry points")
    func orderingOnly() async throws {
        let store = try phase15Store()
        let a = try store.insert(Asset(contentKey: "ocr", mediaType: .image, displayName: "a.jpg"))
        let b = try store.insert(Asset(contentKey: "speech", mediaType: .video, displayName: "b.mov"))
        let moment = try store.insertMoments([Moment(assetID: a.assetID!, startSeconds: 0, endSeconds: 0)])[0]
        try store.insertOCR([OCRText(momentID: moment.momentID!, assetID: a.assetID!, text: "presupuesto")], momentTimes: [moment.momentID!: (0, 0)])
        try store.insertTranscript([TranscriptChunk(assetID: b.assetID!, startSeconds: 60, endSeconds: 64, text: "presupuesto")])
        let plan = SearchPlan(rawQuery: "presupuesto", visualPhrases: [], spokenTerms: ["presupuesto"],
                              literalTerms: ["presupuesto"], mediaType: nil, dateRange: nil, source: .literal)
        var options = SearchEngine.Options()
        options.weights.transcriptTrust = 0.8
        options.weights.onScreenTextTrust = 0.8
        let baseline = try await SearchEngine(store: store, options: options).search(plan: plan, vectorIndex: nil)
        #expect(baseline.count == 2)
        try usageSamples(store)
        options.usesLearnedWeights = true
        let engine = SearchEngine(store: store, options: options)
        let learned = try await engine.search(plan: plan, vectorIndex: nil)
        #expect(learned.map(\.assetID) != baseline.map(\.assetID))
        #expect(Set(learned.map(\.assetID)) == Set(baseline.map(\.assetID)))
        #expect(Dictionary(uniqueKeysWithValues: learned.map { ($0.assetID, $0.score) }) ==
                Dictionary(uniqueKeysWithValues: baseline.map { ($0.assetID, $0.score) }))
        #expect(learned.first?.preferenceExplanation != nil)
        #expect(try engine.searchFast(plan: plan).map(\.assetID) == learned.map(\.assetID))
        var final: [SearchResult] = []
        for try await update in engine.searchProgressively(plan: plan, vectorIndex: nil) { final = update.results }
        #expect(final.map(\.assetID) == learned.map(\.assetID))
        options.limit = 1
        let limited = try await SearchEngine(store: store, options: options).search(plan: plan, vectorIndex: nil)
        #expect(limited.first?.assetID == baseline.first?.assetID)
        try store.forgetUsage()
        #expect(try await engine.search(plan: plan, vectorIndex: nil).map(\.assetID) == baseline.map(\.assetID))
    }

    @Test("Retention is bounded and unobserved seek dwell is not a positive signal")
    func retention() throws {
        let store = try phase15Store()
        try store.setUsageLearningEnabled(true)
        try store.dbPool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 5100)
                INSERT INTO interactions(queryHash, action, channels, createdAt)
                SELECT 'h', 'seek', 'transcript', CURRENT_TIMESTAMP FROM n;
                """)
        }
        try store.record(action: .seek, query: "x", channels: ["transcript"])
        #expect(try store.interactionCount() == 5000)
        #expect(try store.channelPreferences().isEmpty)
    }
}

@Suite("Indexing schedule and disk policy")
struct ScheduleTests {
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: hour, minute: minute))!
    }
    @Test("Daily and overnight windows use inclusive start and exclusive end")
    func boundaries() throws {
        let night = try #require(IndexingWindow("23:00-07:00"))
        #expect(night.contains(date(23)))
        #expect(night.contains(date(0)))
        #expect(night.contains(date(6, 59)))
        #expect(!night.contains(date(7)))
        #expect(!night.contains(date(22, 59)))
        #expect(IndexingWindow("08:30-17:45")!.contains(date(9)))
        #expect(!IndexingWindow("08:30-17:45")!.contains(date(18)))
        #expect(IndexingWindow("00:00-00:00")!.contains(date(12)))
        #expect(IndexingWindow("24:00-07:00") == nil)
        #expect(IndexingWindow("23:99-07:00") == nil)
    }
    @Test("Window blocks workers and discovery, even at full speed; thermal limits remain")
    func governor() {
        var settings = ResourceGovernor.Settings()
        settings.indexingWindow = IndexingWindow("23:00-07:00")
        for mode in [IndexerMode.smart, .fullSpeed] {
            settings.mode = mode
            let governor = ResourceGovernor(settings: settings, snapshot: ResourceSnapshot())
            #expect(governor.decide(now: date(12)).reason == .outsideSchedule)
            #expect(governor.decide(now: date(12)).concurrency == 0)
            #expect(governor.decide(now: date(12)).scanConcurrency == 0)
            #expect(governor.decide(now: date(23)).isWorking)
        }
        #expect(ResourceGovernor(settings: settings, snapshot: ResourceSnapshot(thermalLevel: .critical))
            .decide(now: date(23)).reason == .thermal)
    }
    @Test("DST repeated and missing hours follow the current local wall clock")
    func dst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let window = try #require(IndexingWindow("01:00-03:00"))
        let formatter = ISO8601DateFormatter()
        for time in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            #expect(window.contains(try #require(formatter.date(from: time)), calendar: calendar))
        }
        #expect(!window.contains(try #require(formatter.date(from: "2026-03-08T07:00:00Z")), calendar: calendar))
    }
    @Test("Disk throttling restores thread policy on success and failure")
    func diskScope() {
        let previous = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        BackgroundIO.run { _ = 42 }
        #expect(getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) == previous)
        enum Failure: Error { case expected }
        do { try BackgroundIO.run { throw Failure.expected } } catch {}
        #expect(getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) == previous)
    }
}

@Suite("Portable volume catalog")
struct PortableCatalogTests {
    private func seed(_ store: IndexStore, key: String, volume: String = "disk-A", path: String = "shots/a.mov") throws -> (Int64, Int64) {
        try store.upsertVolume(Volume(volumeUUID: volume, name: volume, bookmark: Data("private-bookmark".utf8)))
        let asset = try store.insert(Asset(contentKey: key, mediaType: .video, durationSeconds: 300,
                                          indexedLevels: [.metadata, .visual, .spoken, .deep], displayName: key + ".mov"))
        let id = asset.assetID!
        try store.dbPool.write { db in
            var location = Location(assetID: id, volumeUUID: volume, relativePath: path, fileSize: 30_000_000_000)
            try location.insert(db)
        }
        let moment = try store.insertMoments([Moment(assetID: id, startSeconds: 120, endSeconds: 125)])[0]
        try store.saveEmbeddings([(moment.momentID!, [1, 0, 0, 0])], modelID: "test-portable")
        try store.insertTranscript([TranscriptChunk(assetID: id, startSeconds: 121, endSeconds: 124,
                                                   text: "presupuesto de campaña", engine: "test-engine")])
        try store.insertOCR([OCRText(momentID: moment.momentID!, assetID: id, text: "FACTURA 4582")],
                            momentTimes: [moment.momentID!: (120, 125)])
        try store.insertLabels([LabelRow(momentID: moment.momentID!, assetID: id, identifier: "meeting", confidence: 0.9, source: "test")],
                               momentTimes: [moment.momentID!: (120, 125)])
        return (id, moment.momentID!)
    }
    private func exportURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wf-" + UUID().uuidString + ".wfindex")
    }

    @Test("Round trip remaps IDs, keeps timecodes, excludes private data and requires no media")
    func roundTrip() async throws {
        let source = try phase15Store()
        let (sourceAsset, sourceMoment) = try seed(source, key: "wanted")
        _ = try seed(source, key: "other-disk-secret", volume: "disk-B")
        try source.setUsageLearningEnabled(true)
        try source.record(action: .open, query: "private search", channels: ["transcript"])
        try await source.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO people(displayName, isNamed, createdAt, updatedAt) VALUES ('biometric-secret', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
                INSERT INTO person_names(name, personID) VALUES ('biometric-secret', 1);
                """)
        }
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = try PortableCatalog.export(store: source, volumeUUID: "disk-A", to: url)
        #expect(manifest.assets == 1 && manifest.moments == 1)
        #expect(try PortableCatalog.inspect(url).sha256 == manifest.sha256)
        var config = Configuration(); config.readonly = true
        let snapshot = try DatabaseQueue(path: url.appendingPathComponent("index.sqlite").path, configuration: config)
        try await snapshot.read { db throws -> Void in
            for table in ["people", "faces", "person_names", "people_feedback", "person_appearances", "interactions", "previews", "jobs"] {
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
            }
            #expect(try Data.fetchOne(db, sql: "SELECT bookmark FROM volumes") == nil)
            #expect(try Bool.fetchOne(db, sql: "SELECT enabled FROM usage_state") == false)
        }
        let raw = try Data(contentsOf: url.appendingPathComponent("index.sqlite"))
        #expect(raw.range(of: Data("biometric-secret".utf8)) == nil)
        #expect(raw.range(of: Data("other-disk-secret".utf8)) == nil)
        let destination = try phase15Store()
        _ = try seed(destination, key: "local", volume: "disk-local")
        let report = try PortableCatalog.importCatalog(from: url, into: destination)
        #expect(report.addedAssets == 1 && report.addedMoments == 1 && report.addedLocations == 1)
        let mapped = try #require(await destination.dbPool.read { try Asset.fetchOne($0, sql: "SELECT * FROM assets WHERE contentKey = 'wanted'") })
        #expect(mapped.assetID != sourceAsset)
        #expect(!mapped.indexedLevels.contains(.deep))
        let importedMoment = try #require(await destination.dbPool.read {
            try Moment.fetchOne($0, sql: "SELECT * FROM moments WHERE assetID = ?", arguments: [mapped.assetID])
        })
        #expect(importedMoment.momentID != sourceMoment)
        #expect(importedMoment.startSeconds == 120)
        let hits = try LinearVectorSearch.search(store: destination, modelID: "test-portable", query: [1, 0, 0, 0], limit: 10)
        #expect(hits.contains { $0.momentID == importedMoment.momentID })
        let plan = SearchPlan(rawQuery: "presupuesto", visualPhrases: [], spokenTerms: ["presupuesto"],
                              literalTerms: [], mediaType: nil, dateRange: nil, source: .literal)
        let results = try await SearchEngine(store: destination).search(plan: plan, vectorIndex: nil)
        let result = try #require(results.first { $0.assetID == mapped.assetID })
        #expect(result.startSeconds == 121)
        #expect(result.locations.first?.availability == .offline)
        #expect(result.locations.first?.url == nil)
        let twice = try PortableCatalog.importCatalog(from: url, into: destination)
        #expect(twice.addedAssets == 0 && twice.addedMoments == 0 && twice.addedLocations == 0)
        #expect(try destination.stats().assets == 2)
        #expect(try destination.stats().transcriptChunks == 2)
        #expect(try destination.stats().pendingJobs == 0)
    }

    @Test("Conflicting paths roll back the entire import and preserve local analysis")
    func conflictRollsBack() throws {
        let source = try phase15Store()
        _ = try seed(source, key: "remote")
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PortableCatalog.export(store: source, volumeUUID: "disk-A", to: url)
        let destination = try phase15Store()
        _ = try seed(destination, key: "local")
        #expect(throws: (any Error).self) { try PortableCatalog.importCatalog(from: url, into: destination) }
        #expect(try destination.stats().assets == 1)
        #expect(try destination.stats().moments == 1)
        #expect(try destination.dbPool.read { try String.fetchOne($0, sql: "SELECT contentKey FROM assets") } == "local")
    }

    @Test("Checksum corruption and existing export destinations never overwrite data")
    func corruption() throws {
        let source = try phase15Store()
        _ = try seed(source, key: "remote")
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PortableCatalog.export(store: source, volumeUUID: "disk-A", to: url)
        #expect(throws: (any Error).self) { try PortableCatalog.export(store: source, volumeUUID: "disk-A", to: url) }
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent("index.sqlite"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()
        let destination = try phase15Store()
        #expect(throws: (any Error).self) { try PortableCatalog.importCatalog(from: url, into: destination) }
        #expect(try destination.stats().assets == 0)
    }

    @Test("Metadata-only local entries receive analysis, preserving their name and identity")
    func enrichExisting() throws {
        let source = try phase15Store()
        _ = try seed(source, key: "remote")
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PortableCatalog.export(store: source, volumeUUID: "disk-A", to: url)
        let destination = try phase15Store()
        let asset = try destination.insert(Asset(contentKey: "remote", mediaType: .video, displayName: "user-renamed.mov"))
        let report = try PortableCatalog.importCatalog(from: url, into: destination)
        #expect(report.addedAssets == 0 && report.addedMoments == 1)
        #expect(try destination.asset(id: asset.assetID!)?.displayName == "user-renamed.mov")
        let filename = try destination.dbPool.read {
            try String.fetchOne($0, sql: "SELECT text FROM search_index WHERE assetID = ? AND kind = 'filename'", arguments: [asset.assetID])
        }
        #expect(filename == "user-renamed.mov")
    }
}

@Suite("Portable index consistency")
struct PortableConsistencyTests {
    @Test("A stale ANN cannot hide imported vectors")
    func staleANN() async throws {
        let store = try phase15Store()
        var ids: [Int64] = []
        let vector: [Float] = [1] + Array(repeating: 0, count: 511)
        for key in ["local", "imported"] {
            let asset = try store.insert(Asset(contentKey: key, mediaType: .image, displayName: key))
            let moment = try store.insertMoments([Moment(assetID: asset.assetID!, startSeconds: 0, endSeconds: 0)])[0]
            ids.append(moment.momentID!)
            try store.saveEmbeddings([(moment.momentID!, vector)], modelID: MobileCLIPVariant.s0.modelID)
        }
        let index = try VectorIndex(modelID: MobileCLIPVariant.s0.modelID, dimensions: 512,
                                    directory: URL(fileURLWithPath: store.dbPool.path).deletingLastPathComponent())
        try await index.openForWriting()
        try await index.add(momentID: ids[0], vector: vector)
        struct Provider: QueryEmbeddingProviding {
            let vector: [Float]
            func embedding(for phrases: [String], variant: MobileCLIPVariant) async throws -> [Float] { vector }
        }
        let plan = SearchPlan(rawQuery: "scene", visualPhrases: ["scene"], spokenTerms: [], literalTerms: [],
                              mediaType: nil, dateRange: nil, source: .literal)
        let results = try await SearchEngine(store: store, embeddingProvider: Provider(vector: vector))
            .search(plan: plan, vectorIndex: index)
        #expect(Set(results.compactMap(\.momentID)) == Set(ids))
    }

    @Test("Journal pages outside the manifest cannot override the snapshot")
    func journalRejected() throws {
        let store = try phase15Store()
        try store.upsertVolume(Volume(volumeUUID: "v", name: "v"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wfindex")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try PortableCatalog.export(store: store, volumeUUID: "v", to: destination)
        try Data([1, 2, 3]).write(to: destination.appendingPathComponent("index.sqlite-wal"))
        #expect(throws: (any Error).self) { try PortableCatalog.inspect(destination) }
    }

    @Test("Exported provenance prevents identical backfills on a fresh Mac")
    func provenance() throws {
        let source = try phase15Store()
        try source.upsertVolume(Volume(volumeUUID: "v", name: "v"))
        try source.prepareOCRBackfill(version: "vision-accurate-1024-v1")
        try source.prepareTranscriptionBackfill(version: "speech-timed-runs-v1")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wfindex")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try PortableCatalog.export(store: source, volumeUUID: "v", to: destination)
        let other = try phase15Store()
        _ = try PortableCatalog.importCatalog(from: destination, into: other)
        #expect(try other.prepareOCRBackfill(version: "vision-accurate-1024-v1") == 0)
        #expect(try other.prepareTranscriptionBackfill(version: "speech-timed-runs-v1") == 0)
        #expect(try other.stats().pendingJobs == 0)
    }
}
