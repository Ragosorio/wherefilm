import Testing
import Foundation
import GRDB
@testable import WhereFilmCore

@Suite("Index store")
struct StoreTests {
    private func makeStore() throws -> IndexStore { try IndexStore.inMemory() }

    private func seedAsset(_ store: IndexStore, key: String = "q1:abc",
                           name: String = "A0045.mov") throws -> Int64 {
        let asset = try store.insert(Asset(
            contentKey: key, mediaType: .video, durationSeconds: 120, displayName: name))
        return try #require(asset.assetID)
    }

    @Test("Stats distinguish discovered, searchable and enriched assets")
    func progressiveCoverageStats() throws {
        let store = try makeStore()
        let firstID = try seedAsset(store, key: "stats:first", name: "FIRST.mov")
        let secondID = try seedAsset(store, key: "stats:second", name: "SECOND.mov")

        try store.addLevels(.metadata, to: firstID)
        try store.addLevels([.metadata, .visual, .spoken], to: secondID)
        let moment = try #require(try store.insertMoments([
            Moment(assetID: secondID, startSeconds: 0, endSeconds: 1),
        ]).first)
        let momentID = try #require(moment.momentID)
        try store.insertOCR([
            OCRText(momentID: momentID, assetID: secondID,
                    text: "CLAQUETA 12", confidence: 0.9),
        ], momentTimes: [momentID: (0, 1)])
        try store.enqueue(assetID: firstID, tasks: [.visual, .ocr])
        try store.enqueue(assetID: secondID, tasks: [.strongHash])

        let stats = try store.stats()
        #expect(stats.assets == 2)
        #expect(stats.searchableAssets == 2)
        #expect(stats.visuallyUnderstoodAssets == 1)
        #expect(stats.transcribedAssets == 1)
        #expect(stats.ocrEnrichedAssets == 1)
        #expect(stats.enrichingAssets == 2, "count assets, not their three queued jobs")
    }

    @Test("Unplugging a drive marks files offline, never missing")
    func offlineIsNotMissing() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "UUID-T7", name: "Samsung T7"))
        let assetID = try seedAsset(store)
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "UUID-T7",
                                          relativePath: "Entrevistas/A0045.mov",
                                          fileSize: 1234))

        // The drive goes in a drawer.
        try store.markVolumes(online: [])

        let locations = try store.locations(assetID: assetID)
        #expect(locations.count == 1)
        #expect(locations[0].availability == .offline)

        // …and comes back.
        try store.markVolumes(online: ["UUID-T7"])
        #expect(try store.locations(assetID: assetID)[0].availability == .online)
    }

    @Test("Renaming a file makes the new name findable and the old one not")
    func renameRefreshesSearchText() throws {
        // Content identity deliberately ignores the path, so a rename keeps the
        // same asset. The searchable *name* did not follow: the filename row is
        // written once by the metadata job, which never re-ran for a file that
        // was not new. The result was a file you could still find by its old
        // name and could not find by its real one.
        let store = try makeStore()
        let assetID = try seedAsset(store, name: "roo pato.png")
        try store.indexMetadataText(assetID: assetID, filename: "roo pato.png",
                                    folder: "Fotos", camera: nil)

        #expect(try !store.textSearch(pattern: "\"pato\"*", kinds: [.filename],
                                      limit: 10).isEmpty)

        // The rename, as the scanner now applies it.
        var asset = try #require(try store.asset(id: assetID))
        asset.displayName = "aaaaa.png"
        try store.update(asset)
        try store.indexMetadataText(assetID: assetID, filename: "aaaaa.png",
                                    folder: "Fotos", camera: nil)

        #expect(try store.asset(id: assetID)?.displayName == "aaaaa.png")
        #expect(try !store.textSearch(pattern: "\"aaaaa\"*", kinds: [.filename],
                                      limit: 10).isEmpty)
        // And the stale name is genuinely gone, not merely outranked.
        #expect(try store.textSearch(pattern: "\"pato\"*", kinds: [.filename],
                                     limit: 10).isEmpty)
    }

    @Test("A deleted original keeps everything the index learned about it")
    func missingKeepsIntelligence() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "UUID-INT", name: "Macintosh HD"))
        let assetID = try seedAsset(store)
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "UUID-INT",
                                          relativePath: "Media/A0045.mov", fileSize: 99))
        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 12, endSeconds: 20,
                            text: "no teníamos presupuesto para eso"),
        ])

        // A scan runs and does not find the file.
        let marked = try store.markMissing(volumeUUID: "UUID-INT", pathPrefix: "Media",
                                           seenPaths: [])
        #expect(marked == 1)
        #expect(try store.locations(assetID: assetID)[0].availability == .missing)

        // The knowledge survives, which is the entire promise.
        #expect(try store.transcriptChunks(assetID: assetID).count == 1)
        let hits = try store.textSearch(pattern: "\"presupuesto\"*")
        #expect(hits.count == 1)
        #expect(hits[0].assetID == assetID)
    }

    @Test("Scanning one folder does not declare the rest of the drive missing")
    func markMissingIsScoped() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "V", name: "Drive"))
        let inScope = try seedAsset(store, key: "q1:one", name: "one.mov")
        let outOfScope = try seedAsset(store, key: "q1:two", name: "two.mov")
        try store.upsertLocation(Location(assetID: inScope, volumeUUID: "V",
                                          relativePath: "PHOTOS/one.mov", fileSize: 1))
        try store.upsertLocation(Location(assetID: outOfScope, volumeUUID: "V",
                                          relativePath: "OTHER/two.mov", fileSize: 1))

        let marked = try store.markMissing(volumeUUID: "V", pathPrefix: "PHOTOS",
                                           seenPaths: [])
        #expect(marked == 1)
        #expect(try store.locations(assetID: inScope)[0].availability == .missing)
        #expect(try store.locations(assetID: outOfScope)[0].availability == .online)
    }

    @Test("A folder prefix never matches a sibling folder")
    func markMissingRespectsDirectoryBoundary() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "V", name: "Drive"))
        let scoped = try seedAsset(store, key: "q1:scoped", name: "scoped.mov")
        let sibling = try seedAsset(store, key: "q1:sibling", name: "sibling.mov")
        try store.upsertLocation(Location(assetID: scoped, volumeUUID: "V",
                                          relativePath: "Media/scoped.mov", fileSize: 1))
        try store.upsertLocation(Location(assetID: sibling, volumeUUID: "V",
                                          relativePath: "Media2/sibling.mov", fileSize: 1))

        let marked = try store.markMissing(volumeUUID: "V", pathPrefix: "Media",
                                           seenPaths: [])
        #expect(marked == 1)
        #expect(try store.locations(assetID: scoped)[0].availability == .missing)
        #expect(try store.locations(assetID: sibling)[0].availability == .online)
    }

    @Test("Nearest preview lookup keeps separate moments for one asset")
    func nearestPreviewsKeepSeparateTargets() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "preview:targets")
        let moments = try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 10),
            Moment(assetID: assetID, startSeconds: 100, endSeconds: 110),
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-preview-targets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = try moments.enumerated().map { index, moment -> (Int64, String) in
            let momentID = try #require(moment.momentID)
            let path = directory.appendingPathComponent("frame-\(index).jpg").path
            try Data("jpeg-\(index)".utf8).write(to: URL(fileURLWithPath: path))
            return (momentID, path)
        }
        try store.dbPool.write { db in
            for (momentID, path) in paths {
                try db.execute(sql: """
                    INSERT INTO previews (momentID, cachePath, bytes, lastUsedAt, pinned)
                    VALUES (?, ?, 1, ?, 0)
                    """, arguments: [momentID, path, Date()])
            }
        }

        let found = try store.nearestPreviewPaths(targets: [
            (assetID: assetID, seconds: 2),
            (assetID: assetID, seconds: 98),
        ])
        #expect(found[0] == paths[0].1)
        #expect(found[1] == paths[1].1)
    }

    @Test("The same footage on three drives is one asset with three locations")
    func duplicatesAcrossDrivesCollapse() throws {
        let store = try makeStore()
        for uuid in ["SSD", "BACKUP", "NAS"] {
            try store.upsertVolume(Volume(volumeUUID: uuid, name: uuid))
        }
        let assetID = try seedAsset(store, key: "q1:shared")
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "SSD",
                                          relativePath: "Entrevistas/A001.mov", fileSize: 10))
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "BACKUP",
                                          relativePath: "2025/A001.mov", fileSize: 10))
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "NAS",
                                          relativePath: "Archive/A001.mov", fileSize: 10))

        #expect(try store.stats().assets == 1)
        #expect(try store.locations(assetID: assetID).count == 3)
    }

    @Test("A file that moved leaves exactly one location behind")
    func movedFilesArePruned() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "V", name: "Drive"))
        let assetID = try seedAsset(store)
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "V",
                                          relativePath: "OLD/A0045.mov", fileSize: 1))
        try store.upsertLocation(Location(assetID: assetID, volumeUUID: "V",
                                          relativePath: "NEW/A0045.mov", fileSize: 1))
        _ = try store.markMissing(volumeUUID: "V", pathPrefix: "",
                                  seenPaths: ["NEW/A0045.mov"])
        #expect(try store.pruneRedundantMissingLocations() == 1)

        let remaining = try store.locations(assetID: assetID)
        #expect(remaining.count == 1)
        #expect(remaining[0].relativePath == "NEW/A0045.mov")
    }

    @Test("Full-text search ignores accents and case")
    func diacriticInsensitiveSearch() throws {
        let store = try makeStore()
        try store.upsertVolume(Volume(volumeUUID: "V", name: "Drive"))
        let assetID = try seedAsset(store)
        try store.insertTranscript([
            TranscriptChunk(assetID: assetID, startSeconds: 0, endSeconds: 5,
                            text: "el Presupuesto se agotó en Guatemala"),
        ])
        #expect(try store.textSearch(pattern: "\"presupuesto\"").count == 1)
        #expect(try store.textSearch(pattern: "\"agoto\"").count == 1)
        #expect(try store.textSearch(pattern: "\"GUATEMALA\"").count == 1)
    }

    @Test("Jobs for one asset serialize while different assets can run together")
    func jobsAreClaimedSafely() throws {
        let store = try makeStore()
        let firstAsset = try seedAsset(store, key: "q1:first")
        let secondAsset = try seedAsset(store, key: "q1:second")
        try store.enqueue(assetID: firstAsset, tasks: [.metadata, .visual])
        try store.enqueue(assetID: secondAsset, tasks: [.metadata])

        let first = try #require(try store.claimNextJob(tasks: JobTask.allCases))
        let second = try #require(try store.claimNextJob(tasks: JobTask.allCases))
        #expect(first.task == .metadata)
        #expect(second.task == .metadata)
        #expect(first.assetID != second.assetID)
        // The visual job for `firstAsset` cannot race its metadata job.
        #expect(try store.claimNextJob(tasks: JobTask.allCases) == nil)

        // A crash mid-job must not strand work forever.
        try store.requeueStaleJobs()
        let retried = try #require(try store.claimNextJob(tasks: JobTask.allCases))
        #expect(retried.task == .metadata)
        try store.complete(job: retried)

        let otherMetadata = try #require(try store.claimNextJob(tasks: JobTask.allCases))
        #expect(otherMetadata.task == .metadata)
        try store.complete(job: otherMetadata)

        // Once the first stage finishes, the next stage for that asset unlocks.
        let next = try #require(try store.claimNextJob(tasks: JobTask.allCases))
        #expect(next.assetID == firstAsset)
        #expect(next.task == .visual)
    }

    @Test("A job gives up after three failures")
    func jobsStopRetryingForever() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store)
        try store.enqueue(assetID: assetID, tasks: [.transcribe])
        for _ in 0..<3 {
            guard let job = try store.claimNextJob(tasks: [.transcribe]) else { break }
            try store.fail(job: job, error: "boom")
        }
        #expect(try store.claimNextJob(tasks: [.transcribe]) == nil)
        #expect(try store.stats().failedJobs == 1)
    }

    @Test("Analysis upgrades enqueue exactly once per algorithm version")
    func derivedAnalysisBackfillsAreVersioned() throws {
        let store = try makeStore()
        var visual = Asset(contentKey: "q1:visual", mediaType: .image,
                           indexedLevels: .visual, displayName: "sign.png")
        visual = try store.insert(visual)
        let visualID = try #require(visual.assetID)
        _ = try store.insertMoments([Moment(assetID: visualID, startSeconds: 0, endSeconds: 0)])

        let spokenID = try seedAsset(store, key: "q1:spoken", name: "meeting.mov")
        try store.insertTranscript([
            TranscriptChunk(assetID: spokenID, startSeconds: 0, endSeconds: 60,
                            text: "presupuesto frente al mar"),
        ])

        #expect(try store.prepareOCRBackfill(version: "ocr-v1") == 1)
        #expect(try store.prepareTranscriptionBackfill(version: "speech-v1") == 1)
        let first = try #require(try store.claimNextJob(tasks: [.ocr, .transcribe]))
        let second = try #require(try store.claimNextJob(tasks: [.ocr, .transcribe]))
        #expect([first.task, second.task].contains(.ocr))
        #expect([first.task, second.task].contains(.transcribe))
        try store.complete(job: first)
        try store.complete(job: second)

        // Relaunching the same build does not redo anything.
        #expect(try store.prepareOCRBackfill(version: "ocr-v1") == 0)
        #expect(try store.prepareTranscriptionBackfill(version: "speech-v1") == 0)
        #expect(try store.claimNextJob(tasks: [.ocr, .transcribe]) == nil)

        // A future algorithm revision can selectively ask for a refresh.
        #expect(try store.prepareOCRBackfill(version: "ocr-v2") == 1)
        #expect(try store.claimNextJob(tasks: [.ocr])?.task == .ocr)
    }

    @Test("OCR refreshes replace stale text and visual reindex removes its FTS rows")
    func ocrReplacementIsAtomic() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "q1:ocr", name: "slate.png")
        let moments = try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5),
        ])
        let momentID = try #require(moments.first?.momentID)
        try store.insertOCR([
            OCRText(momentID: momentID, assetID: assetID, text: "OLD SLATE"),
        ], momentTimes: [momentID: (0, 5)])
        #expect(try !store.textSearch(pattern: "\"old\"*", kinds: [.ocr]).isEmpty)

        try store.replaceOCR(assetID: assetID, texts: [
            OCRText(momentID: momentID, assetID: assetID, text: "NEW TEAM MEMBER"),
        ], momentTimes: [momentID: (0, 5)])
        #expect(try store.textSearch(pattern: "\"old\"*", kinds: [.ocr]).isEmpty)
        #expect(try !store.textSearch(pattern: "\"member\"*", kinds: [.ocr]).isEmpty)

        try store.deleteMoments(assetID: assetID)
        #expect(try store.textSearch(pattern: "\"member\"*", kinds: [.ocr]).isEmpty)
    }

    @Test("A library whose derived rows lost their moments can still be opened")
    func orphanedDerivedRowsDoNotBlockMigration() throws {
        // Taken from a real index, not invented: 151 assets, zero moments, and
        // 262 preview rows still pointing at moments that had gone. SQLite
        // verifies deferred foreign keys when a migration commits, so every
        // migration after the first one failed and the app could not open its
        // own database at all.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wherefilm-orphans-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let assetID: Int64
        let momentID: Int64
        do {
            let store = try IndexStore(url: url)
            assetID = try seedAsset(store, key: "orphan:1", name: "ORPHAN.mov")
            let moment = try #require(try store.insertMoments([
                Moment(assetID: assetID, startSeconds: 0, endSeconds: 4),
            ]).first)
            momentID = try #require(moment.momentID)
            try store.insertOCR(
                [OCRText(momentID: momentID, assetID: assetID, text: "CLAQUETA 3",
                         confidence: 0.9)],
                momentTimes: [momentID: (0, 4)])

            // Orphan the derived rows the way the damaged library was orphaned:
            // the moment disappears while its children survive.
            try store.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                try db.execute(sql: """
                    INSERT INTO previews (momentID, cachePath, bytes, lastUsedAt, pinned)
                    VALUES (?, '/tmp/nowhere.jpg', 1, ?, 0)
                    """, arguments: [momentID, Date()])
                try db.execute(sql: """
                    INSERT INTO search_index
                        (text, assetID, momentID, kind, startSeconds, endSeconds)
                    VALUES ('staleorphan', ?, 999999999, 'ocr', 0, 1)
                    """, arguments: [assetID])
                try db.execute(sql: "DELETE FROM moments WHERE momentID = ?",
                               arguments: [momentID])
                // Wind the schema back to exactly where the damaged library was
                // stuck: everything `v1` created, and nothing after it.
                try db.execute(sql: "DROP TABLE IF EXISTS analysis_state")
                try db.execute(sql: "DROP TABLE IF EXISTS search_vocab")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_ocr_asset")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier <> 'v1'")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }

        // Reopening must succeed, run every migration, and leave the asset —
        // which was never the damaged part — completely intact.
        let reopened = try IndexStore(url: url)
        let stats = try reopened.stats()
        #expect(stats.assets == 1)
        #expect(try reopened.asset(id: assetID)?.displayName == "ORPHAN.mov")

        let violations = try reopened.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_foreign_key_check") ?? 0
        }
        #expect(violations == 0, "the repair must leave no dangling references behind")
        #expect(try reopened.textSearch(pattern: "\"staleorphan\"").isEmpty,
                "FTS payloads are not protected by SQLite foreign keys")
    }

    @Test("One grouped text search returns what separate per-kind searches would")
    func groupedTextSearchMatchesSeparateSearches() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "grouped:1", name: "PRESUPUESTO_01.mov")
        try store.indexMetadataText(assetID: assetID, filename: "PRESUPUESTO_01.mov",
                                    folder: "CLIENTE_A", camera: nil)
        try store.insertTranscript((0..<40).map { index in
            TranscriptChunk(assetID: assetID, startSeconds: Double(index) * 10,
                            endSeconds: Double(index) * 10 + 10,
                            text: "hablamos del presupuesto numero \(index)")
        })

        let pattern = "\"presupuesto\"*"
        let grouped = try store.textSearch(
            pattern: pattern,
            groups: [[.transcript], [.filename, .folder, .metadata, .note]],
            limitPerGroup: 5)
        let transcripts = try store.textSearch(pattern: pattern, kinds: [.transcript], limit: 5)
        let metadata = try store.textSearch(
            pattern: pattern, kinds: [.filename, .folder, .metadata, .note], limit: 5)

        #expect(grouped[0].map(\.text) == transcripts.map(\.text))
        #expect(grouped[1].map(\.text) == metadata.map(\.text))
        // The metadata group is starved by the transcript rows in the wide scan,
        // so this also exercises the top-up path.
        #expect(!grouped[1].isEmpty)
    }

    @Test("The index reports how broad a prefix would be before searching on it")
    func prefixBreadthReflectsTheVocabulary() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "breadth:1", name: "B.mov")
        try store.insertTranscript((0..<50).map { index in
            TranscriptChunk(assetID: assetID, startSeconds: Double(index),
                            endSeconds: Double(index) + 1,
                            text: index < 45 ? "manera de trabajar" : "mano derecha")
        })

        // "man" reaches every row through *manera* and *mano*; "manera" reaches
        // only its own. That gap is the whole point of asking before searching.
        #expect(try store.prefixBreadth("man") == 50)
        #expect(try store.prefixBreadth("manera") == 45)
        #expect(try store.prefixBreadth("zzz") == 0)
    }

    @Test("Embeddings round-trip through the database")
    func embeddingsRoundTrip() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store)
        let moments = try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5),
        ])
        let momentID = try #require(moments[0].momentID)

        var vector = [Float](repeating: 0, count: 512)
        for i in vector.indices { vector[i] = Float.random(in: -1...1) }
        try store.saveEmbeddings([(momentID, vector)], modelID: "test-model")

        var recovered: [Float] = []
        try store.forEachEmbedding(modelID: "test-model") { batch in
            recovered = batch.first?.vector ?? []
        }
        #expect(recovered.count == 512)

        // int8 quantization is lossy by design; what matters is that direction
        // survives, because cosine similarity is all we ever ask of it.
        let expected = VectorCodec.normalized(vector)
        #expect(VectorCodec.dot(expected, VectorCodec.normalized(recovered)) > 0.999)
    }
}
