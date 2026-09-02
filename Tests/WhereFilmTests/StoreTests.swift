import Testing
import Foundation
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
