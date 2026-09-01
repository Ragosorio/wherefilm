import Foundation
import GRDB

/// Everything the app knows, in one file.
///
/// `IndexStore` is the canonical truth. The USearch index next to it is derived
/// and disposable: if it is corrupted, or the visual model changes, it can be
/// thrown away and rebuilt from `embeddings` without losing a single transcript.
public final class IndexStore: Sendable {
    public let dbPool: DatabasePool

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // WAL plus a generous mmap: the indexer writes while searches read,
            // and neither should ever block the other.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }

        dbPool = try DatabasePool(path: url.path, configuration: config)
        try Schema.migrator.migrate(dbPool)
    }

    /// In-memory store, for tests.
    public static func inMemory() throws -> IndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wherefilm-test-\(UUID().uuidString).sqlite")
        return try IndexStore(url: url)
    }

    // MARK: - Volumes

    public func upsertVolume(_ volume: Volume) throws {
        try dbPool.write { db in
            try volume.upsert(db)
        }
    }

    public func markVolumes(online onlineUUIDs: Set<String>) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE volumes SET isOnline = 0")

            // Unplugging *every* drive is a completely ordinary Tuesday, and it
            // must still mark those files offline rather than quietly doing
            // nothing — so the empty case is handled first, not skipped.
            guard !onlineUUIDs.isEmpty else {
                try db.execute(sql: """
                    UPDATE locations SET availability = 'offline' WHERE availability = 'online'
                    """)
                return
            }

            let placeholders = databaseQuestionMarks(count: onlineUUIDs.count)
            let uuids = Array(onlineUUIDs)

            try db.execute(
                sql: "UPDATE volumes SET isOnline = 1, lastSeenAt = ? WHERE volumeUUID IN (\(placeholders))",
                arguments: StatementArguments([Date()] as [any DatabaseValueConvertible])
                    + StatementArguments(uuids))

            // Locations follow their volume: unplugging a drive makes its files
            // `offline`, and that is emphatically not `missing`.
            try db.execute(sql: """
                UPDATE locations SET availability = 'offline'
                WHERE availability = 'online'
                  AND volumeUUID NOT IN (\(placeholders))
                """, arguments: StatementArguments(uuids))
            try db.execute(sql: """
                UPDATE locations SET availability = 'online'
                WHERE availability = 'offline'
                  AND volumeUUID IN (\(placeholders))
                """, arguments: StatementArguments(uuids))
        }
    }

    public func volumes() throws -> [Volume] {
        try dbPool.read { db in try Volume.fetchAll(db) }
    }

    public func volume(uuid: String) throws -> Volume? {
        try dbPool.read { db in try Volume.fetchOne(db, key: uuid) }
    }

    // MARK: - Assets & locations

    public func asset(contentKey: String) throws -> Asset? {
        try dbPool.read { db in
            try Asset.filter(Column("contentKey") == contentKey).fetchOne(db)
        }
    }

    public func asset(id: Int64) throws -> Asset? {
        try dbPool.read { db in try Asset.fetchOne(db, key: id) }
    }

    public func assets(ids: [Int64]) throws -> [Int64: Asset] {
        guard !ids.isEmpty else { return [:] }
        return try dbPool.read { db in
            let rows = try Asset.filter(ids.contains(Column("assetID"))).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { a in
                a.assetID.map { ($0, a) }
            })
        }
    }

    @discardableResult
    public func insert(_ asset: Asset) throws -> Asset {
        var copy = asset
        try dbPool.write { db in try copy.insert(db) }
        return copy
    }

    public func update(_ asset: Asset) throws {
        try dbPool.write { db in try asset.update(db) }
    }

    public func addLevels(_ levels: IndexLevels, to assetID: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE assets SET indexedLevels = indexedLevels | ? WHERE assetID = ?",
                arguments: [levels.rawValue, assetID])
        }
    }

    /// Records where a file was seen. Re-seeing the same (volume, path) updates
    /// it rather than creating a duplicate, and the same content on a second
    /// drive simply becomes a second location for the *same* asset.
    @discardableResult
    public func upsertLocation(_ location: Location) throws -> Location {
        try dbPool.write { db in
            if var existing = try Location
                .filter(Column("volumeUUID") == location.volumeUUID
                        && Column("relativePath") == location.relativePath)
                .fetchOne(db) {
                existing.assetID = location.assetID
                existing.fileSize = location.fileSize
                existing.modifiedAt = location.modifiedAt
                existing.availability = location.availability
                existing.lastSeenAt = location.lastSeenAt
                try existing.update(db)
                return existing
            }
            var copy = location
            try copy.insert(db)
            return copy
        }
    }

    public func locations(assetID: Int64) throws -> [Location] {
        try dbPool.read { db in
            try Location.filter(Column("assetID") == assetID)
                .order(Column("availability"), Column("lastSeenAt").desc)
                .fetchAll(db)
        }
    }

    public func locations(assetIDs: [Int64]) throws -> [Int64: [Location]] {
        guard !assetIDs.isEmpty else { return [:] }
        return try dbPool.read { db in
            let rows = try Location.filter(assetIDs.contains(Column("assetID"))).fetchAll(db)
            return Dictionary(grouping: rows, by: \.assetID)
        }
    }

    /// Marks paths we looked for and did not find. Never deletes anything: a
    /// missing original keeps its transcript, its embeddings, its previews and
    /// its last known location. "Deleted from disk" and "forgotten" are not the
    /// same thing, and only the first one is the user's decision.
    ///
    /// Scoped to `pathPrefix` — the folder that was actually walked — so scanning
    /// one subfolder never declares the rest of the drive missing.
    public func markMissing(volumeUUID: String, pathPrefix: String,
                            seenPaths: Set<String>) throws -> Int {
        try dbPool.write { db in
            let all = try Location.filter(Column("volumeUUID") == volumeUUID).fetchAll(db)
            var count = 0
            for var location in all {
                guard location.availability == .online,
                      pathPrefix.isEmpty || location.relativePath.hasPrefix(pathPrefix),
                      !seenPaths.contains(location.relativePath) else { continue }
                location.availability = .missing
                try location.update(db)
                count += 1
            }
            return count
        }
    }

    /// Drops `missing` pointers for assets that also have a reachable location.
    /// The file moved; it was not lost, and one stale row per move would pile up
    /// forever.
    @discardableResult
    public func pruneRedundantMissingLocations() throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: """
                DELETE FROM locations WHERE availability = 'missing' AND assetID IN (
                    SELECT assetID FROM locations WHERE availability IN ('online', 'offline')
                )
                """)
            return db.changesCount
        }
    }

    // MARK: - Moments & embeddings

    @discardableResult
    public func insertMoments(_ moments: [Moment]) throws -> [Moment] {
        try dbPool.write { db in
            var out: [Moment] = []
            out.reserveCapacity(moments.count)
            for moment in moments {
                var copy = moment
                try copy.insert(db)
                out.append(copy)
            }
            return out
        }
    }

    public func moments(assetID: Int64) throws -> [Moment] {
        try dbPool.read { db in
            try Moment.filter(Column("assetID") == assetID)
                .order(Column("startSeconds")).fetchAll(db)
        }
    }

    public func moments(ids: [Int64]) throws -> [Int64: Moment] {
        guard !ids.isEmpty else { return [:] }
        return try dbPool.read { db in
            let rows = try Moment.filter(ids.contains(Column("momentID"))).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { m in
                m.momentID.map { ($0, m) }
            })
        }
    }

    public func deleteMoments(assetID: Int64) throws {
        _ = try dbPool.write { db in
            try Moment.filter(Column("assetID") == assetID).deleteAll(db)
        }
    }

    public func saveEmbeddings(
        _ pairs: [(momentID: Int64, vector: [Float])],
        modelID: String,
        quantization: VectorQuantization = .int8
    ) throws {
        try dbPool.write { db in
            for (momentID, vector) in pairs {
                let unit = VectorCodec.normalized(vector)
                let (data, scale) = VectorCodec.encode(unit, as: quantization)
                try db.execute(sql: """
                    INSERT INTO embeddings (momentID, modelID, dimensions, quantization, scale, vector)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(momentID, modelID) DO UPDATE SET
                        dimensions = excluded.dimensions,
                        quantization = excluded.quantization,
                        scale = excluded.scale,
                        vector = excluded.vector
                    """, arguments: [momentID, modelID, unit.count, quantization.rawValue, scale, data])
            }
        }
    }

    public struct StoredEmbedding: Sendable {
        public let momentID: Int64
        public let vector: [Float]
    }

    /// Streams every vector for a model — this is what rebuilds the ANN index
    /// from scratch after a corruption or a model change.
    public func forEachEmbedding(
        modelID: String,
        batchSize: Int = 4096,
        _ body: ([StoredEmbedding]) throws -> Void
    ) throws {
        var lastID: Int64 = 0
        while true {
            let batch: [StoredEmbedding] = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT momentID, quantization, scale, vector FROM embeddings
                    WHERE modelID = ? AND momentID > ?
                    ORDER BY momentID LIMIT ?
                    """, arguments: [modelID, lastID, batchSize])
                    .map { row in
                        let quantization = VectorQuantization(
                            rawValue: row["quantization"]) ?? .int8
                        return StoredEmbedding(
                            momentID: row["momentID"],
                            vector: VectorCodec.decode(row["vector"], scale: row["scale"],
                                                       quantization: quantization))
                    }
            }
            guard !batch.isEmpty else { return }
            try body(batch)
            lastID = batch.last!.momentID
        }
    }

    public func embeddingCount(modelID: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM embeddings WHERE modelID = ?",
                             arguments: [modelID]) ?? 0
        }
    }

    // MARK: - Text

    public func insertTranscript(_ chunks: [TranscriptChunk]) throws {
        try dbPool.write { db in
            for chunk in chunks {
                var copy = chunk
                try copy.insert(db)
                try Self.indexText(db, text: chunk.text, assetID: chunk.assetID,
                                   momentID: nil, kind: .transcript,
                                   start: chunk.startSeconds, end: chunk.endSeconds)
            }
        }
    }

    public func deleteTranscript(assetID: Int64) throws {
        try dbPool.write { db in
            _ = try TranscriptChunk.filter(Column("assetID") == assetID).deleteAll(db)
            try db.execute(sql: "DELETE FROM search_index WHERE assetID = ? AND kind = ?",
                           arguments: [assetID, SearchTextKind.transcript.rawValue])
        }
    }

    public func insertOCR(_ texts: [OCRText], momentTimes: [Int64: (Double, Double)]) throws {
        try dbPool.write { db in
            for ocr in texts {
                var copy = ocr
                try copy.insert(db)
                let times = momentTimes[ocr.momentID] ?? (0, 0)
                try Self.indexText(db, text: ocr.text, assetID: ocr.assetID,
                                   momentID: ocr.momentID, kind: .ocr,
                                   start: times.0, end: times.1)
            }
        }
    }

    /// Filenames, folder names and camera metadata go into the same FTS5 table as
    /// transcripts. "the interview in the CLIENT_A folder" should work.
    public func indexMetadataText(assetID: Int64, filename: String, folder: String,
                                  camera: String?) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM search_index WHERE assetID = ? AND kind IN (?, ?, ?)",
                           arguments: [assetID, SearchTextKind.filename.rawValue,
                                       SearchTextKind.folder.rawValue,
                                       SearchTextKind.metadata.rawValue])
            // No massaging needed: FTS5's unicode61 tokenizer already splits
            // INTERVIEW_JUAN_03.mov into "interview", "juan", "03", "mov".
            try Self.indexText(db, text: filename, assetID: assetID, momentID: nil,
                               kind: .filename, start: 0, end: 0)
            try Self.indexText(db, text: folder, assetID: assetID, momentID: nil,
                               kind: .folder, start: 0, end: 0)
            if let camera, !camera.isEmpty {
                try Self.indexText(db, text: camera, assetID: assetID, momentID: nil,
                                   kind: .metadata, start: 0, end: 0)
            }
        }
    }

    static func indexText(_ db: Database, text: String, assetID: Int64, momentID: Int64?,
                          kind: SearchTextKind, start: Double, end: Double) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.execute(sql: """
            INSERT INTO search_index (text, assetID, momentID, kind, startSeconds, endSeconds)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [trimmed, assetID, momentID, kind.rawValue, start, end])
    }

    public struct TextHit: Sendable {
        public let assetID: Int64
        public let momentID: Int64?
        public let kind: SearchTextKind
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String
        public let snippet: String
        /// Lower (more negative) bm25 is better; we flip it so higher is better.
        public let score: Double
    }

    /// Full-text search over transcripts, OCR and metadata.
    /// `pattern` must already be a valid FTS5 MATCH expression.
    public func textSearch(pattern: String, kinds: [SearchTextKind]? = nil,
                           limit: Int = 200) throws -> [TextHit] {
        try dbPool.read { db in
            var sql = """
                SELECT text, assetID, momentID, kind, startSeconds, endSeconds,
                       bm25(search_index, 10.0) AS rank,
                       snippet(search_index, 0, '«', '»', '…', 12) AS snip
                FROM search_index
                WHERE search_index MATCH ?
                """
            var arguments: [any DatabaseValueConvertible] = [pattern]
            if let kinds, !kinds.isEmpty {
                sql += " AND kind IN (\(databaseQuestionMarks(count: kinds.count)))"
                arguments += kinds.map(\.rawValue)
            }
            sql += " ORDER BY rank LIMIT ?"
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { row in
                    TextHit(
                        assetID: row["assetID"],
                        momentID: row["momentID"],
                        kind: SearchTextKind(rawValue: row["kind"]) ?? .metadata,
                        startSeconds: row["startSeconds"],
                        endSeconds: row["endSeconds"],
                        text: row["text"],
                        snippet: row["snip"] ?? "",
                        score: -(row["rank"] as Double))
                }
        }
    }

    public func transcriptChunks(assetID: Int64) throws -> [TranscriptChunk] {
        try dbPool.read { db in
            try TranscriptChunk.filter(Column("assetID") == assetID)
                .order(Column("startSeconds")).fetchAll(db)
        }
    }

    /// The transcript line closest to a given instant — used to caption a visual
    /// hit with what was being said at that moment.
    public func transcriptNear(assetID: Int64, seconds: Double,
                               window: Double = 30) throws -> TranscriptChunk? {
        try dbPool.read { db in
            try TranscriptChunk
                .filter(Column("assetID") == assetID)
                .filter(Column("endSeconds") >= seconds - window)
                .filter(Column("startSeconds") <= seconds + window)
                .order(abs(Column("startSeconds") - seconds))
                .fetchOne(db)
        }
    }

    // MARK: - Jobs

    public func enqueue(assetID: Int64, tasks: [JobTask]) throws {
        try dbPool.write { db in
            for task in tasks {
                try db.execute(sql: """
                    INSERT INTO jobs (assetID, task, state, priority, attempts, updatedAt)
                    VALUES (?, ?, 'pending', ?, 0, ?)
                    ON CONFLICT(assetID, task) DO UPDATE SET
                        state = CASE WHEN jobs.state = 'done' THEN 'done' ELSE 'pending' END,
                        updatedAt = excluded.updatedAt
                    """, arguments: [assetID, task.rawValue, task.defaultPriority, Date()])
            }
        }
    }

    /// Atomically takes the next job of an allowed kind. Returns nil when the
    /// queue is empty, which is the indexer's cue to go back to sleep instead of
    /// spinning.
    public func claimNextJob(tasks: [JobTask]) throws -> Job? {
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: tasks.count)
            guard var job = try Job.fetchOne(db, sql: """
                SELECT * FROM jobs
                WHERE state = 'pending' AND task IN (\(placeholders)) AND attempts < 3
                ORDER BY priority, jobID LIMIT 1
                """, arguments: StatementArguments(tasks.map(\.rawValue))) else { return nil }
            job.state = .running
            job.updatedAt = Date()
            try job.update(db)
            return job
        }
    }

    public func complete(job: Job) throws {
        try dbPool.write { db in
            var copy = job
            copy.state = .done
            copy.lastError = nil
            copy.updatedAt = Date()
            try copy.update(db)
        }
    }

    public func fail(job: Job, error: String) throws {
        try dbPool.write { db in
            var copy = job
            copy.attempts += 1
            copy.state = copy.attempts >= 3 ? .failed : .pending
            copy.lastError = String(error.prefix(500))
            copy.updatedAt = Date()
            try copy.update(db)
        }
    }

    /// Anything left `running` after a crash goes back in the queue.
    public func requeueStaleJobs() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'pending' WHERE state = 'running'")
        }
    }

    // MARK: - Models

    public func register(model: ModelRecord) throws {
        try dbPool.write { db in try model.upsert(db) }
    }

    // MARK: - Stats

    public struct Stats: Sendable {
        public var assets = 0
        public var moments = 0
        public var embeddings = 0
        public var transcriptChunks = 0
        public var volumesOnline = 0
        public var volumesOffline = 0
        public var pendingJobs = 0
        public var failedJobs = 0
        public var missingLocations = 0
        public var databaseBytes: Int64 = 0

        public init() {}
    }

    public func stats() throws -> Stats {
        try dbPool.read { db in
            var stats = Stats()
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }
            stats.assets = try count("SELECT count(*) FROM assets")
            stats.moments = try count("SELECT count(*) FROM moments")
            stats.embeddings = try count("SELECT count(*) FROM embeddings")
            stats.transcriptChunks = try count("SELECT count(*) FROM transcript_chunks")
            stats.volumesOnline = try count("SELECT count(*) FROM volumes WHERE isOnline = 1")
            stats.volumesOffline = try count("SELECT count(*) FROM volumes WHERE isOnline = 0")
            stats.pendingJobs = try count("SELECT count(*) FROM jobs WHERE state IN ('pending','running')")
            stats.failedJobs = try count("SELECT count(*) FROM jobs WHERE state = 'failed'")
            stats.missingLocations = try count("SELECT count(*) FROM locations WHERE availability = 'missing'")
            return stats
        }
    }
}

// MARK: - Helpers

func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
