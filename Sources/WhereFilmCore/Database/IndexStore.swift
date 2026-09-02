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

        // Only worth doing when a migration is about to run, which is the only
        // moment SQLite verifies deferred foreign keys — and measurably so: the
        // scan costs 260 ms on a 1.4 M-row library, against 20 ms to open a
        // healthy one. Paying that once per app upgrade is right; paying it at
        // every launch is not.
        let migrator = Schema.migrator
        let pending = try dbPool.read { db in
            try !migrator.hasCompletedMigrations(db)
        }
        if pending { try Self.repairOrphanedDerivedRows(dbPool) }
        try migrator.migrate(dbPool)
    }

    /// Drops derived rows whose parent moment is gone, before migrating.
    ///
    /// Found on a real library, not imagined. That index held 151 assets, zero
    /// moments, and 262 preview rows plus 119 OCR rows still pointing at moments
    /// that no longer existed. Because SQLite checks deferred foreign keys when a
    /// migration commits, *every* migration after `v1` failed on those orphans —
    /// so the app could not open its own database at all, and had not been able
    /// to since `v2` shipped. The failure had nothing to do with the migration
    /// being applied; it was pre-existing damage that only a schema change made
    /// fatal.
    ///
    /// Repairing rather than refusing is the right call here because of what is
    /// being deleted. Previews are a budgeted cache and OCR is recomputable from
    /// keyframes; both are explicitly derived state that the pipeline knows how
    /// to rebuild. No original, transcript, or asset identity is touched. The
    /// alternative — a database nobody can open — protects nothing.
    ///
    /// Runs on every open and must therefore stay cheap: each check is an
    /// indexed anti-join that stops at the first orphan, and the deletes only
    /// run when there is something to delete.
    private static func repairOrphanedDerivedRows(_ pool: DatabasePool) throws {
        let orphanChecks = [
            ("locations", "volumeUUID", "volumes", "volumeUUID"),
            ("previews", "momentID", "moments", "momentID"),
            ("ocr_texts", "momentID", "moments", "momentID"),
            ("ocr_texts", "assetID", "assets", "assetID"),
            ("embeddings", "momentID", "moments", "momentID"),
            ("moments", "assetID", "assets", "assetID"),
            ("transcript_chunks", "assetID", "assets", "assetID"),
            ("locations", "assetID", "assets", "assetID"),
            ("jobs", "assetID", "assets", "assetID"),
        ]

        try pool.writeWithoutTransaction { db in
            // A table that does not exist yet is not damaged; a brand-new
            // database reaches this before any migration has run.
            let existing = Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                """))

            for (child, childKey, parent, parentKey) in orphanChecks {
                guard existing.contains(child), existing.contains(parent) else { continue }
                let hasOrphan = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM \(child) c
                    WHERE NOT EXISTS (
                        SELECT 1 FROM \(parent) p WHERE p.\(parentKey) = c.\(childKey)
                    )
                    LIMIT 1
                    """) != nil
                guard hasOrphan else { continue }
                try db.execute(sql: """
                    DELETE FROM \(child)
                    WHERE NOT EXISTS (
                        SELECT 1 FROM \(parent) p WHERE p.\(parentKey) = \(child).\(childKey)
                    )
                    """)
            }

            // FTS5 stores asset/moment IDs as UNINDEXED payload columns, so
            // SQLite's foreign-key checker cannot see stale rows there. They
            // must be repaired explicitly or deleted OCR/metadata can remain
            // searchable after a damaged migration.
            if existing.contains("search_index"), existing.contains("assets"),
               existing.contains("moments") {
                try db.execute(sql: """
                    DELETE FROM search_index
                    WHERE (assetID IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM assets a WHERE a.assetID = search_index.assetID
                    ))
                       OR (momentID IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM moments m WHERE m.momentID = search_index.momentID
                    ))
                    """)
            }
        }
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

    /// Finds the catalog entry for an exact path without touching the media.
    ///
    /// This is the hot path for repeat scans. If size and modification date are
    /// unchanged, the scanner can refresh `lastSeenAt` and move on instead of
    /// opening a multi-gigabyte container and hashing three regions again.
    public func location(volumeUUID: String, relativePath: String) throws -> Location? {
        try dbPool.read { db in
            try Location
                .filter(Column("volumeUUID") == volumeUUID
                        && Column("relativePath") == relativePath)
                .fetchOne(db)
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
            let prefix = pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var count = 0
            // Stream only online rows. A full-volume rescan can have hundreds
            // of thousands of locations; loading every record just to mark a
            // handful missing needlessly duplicates the catalog in RAM.
            let cursor = try Location
                .filter(Column("volumeUUID") == volumeUUID)
                .filter(Column("availability") == Availability.online.rawValue)
                .fetchCursor(db)
            while var location = try cursor.next() {
                let isInScope = prefix.isEmpty
                    || location.relativePath == prefix
                    || location.relativePath.hasPrefix(prefix + "/")
                guard location.availability == .online,
                      isInScope,
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
            // FTS5 is not a foreign-key child of moments, so it must be cleaned
            // explicitly before a visual re-index creates replacement moments.
            try db.execute(sql: "DELETE FROM search_index WHERE assetID = ? AND kind = ?",
                           arguments: [assetID, SearchTextKind.ocr.rawValue])
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
            try Self.insertOCR(texts, momentTimes: momentTimes, in: db)
        }
    }

    /// Atomically swaps the OCR channel after a higher-quality backfill. If the
    /// re-decode or recognition fails, the caller never reaches this method and
    /// the old searchable text remains available.
    public func replaceOCR(assetID: Int64, texts: [OCRText],
                           momentTimes: [Int64: (Double, Double)]) throws {
        try dbPool.write { db in
            _ = try OCRText.filter(Column("assetID") == assetID).deleteAll(db)
            try db.execute(sql: "DELETE FROM search_index WHERE assetID = ? AND kind = ?",
                           arguments: [assetID, SearchTextKind.ocr.rawValue])
            try Self.insertOCR(texts, momentTimes: momentTimes, in: db)
        }
    }

    private static func insertOCR(_ texts: [OCRText],
                                  momentTimes: [Int64: (Double, Double)],
                                  in db: Database) throws {
        for ocr in texts {
            var copy = ocr
            try copy.insert(db)
            let times = momentTimes[ocr.momentID] ?? (0, 0)
            try indexText(db, text: ocr.text, assetID: ocr.assetID,
                          momentID: ocr.momentID, kind: .ocr,
                          start: times.0, end: times.1)
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

    /// How broad a prefix term would be, straight from FTS5's own term
    /// dictionary.
    ///
    /// A prefix wildcard is not uniformly cheap. Measured on a 1.5 M-row index,
    /// `"camis"*` reaches 62 K rows and ranks in 50 ms, while `"man"*` reaches
    /// 517 K rows — a third of the whole corpus, because Spanish is full of
    /// words like *manera* — and ranks in 490 ms. Length does not predict this;
    /// only the vocabulary does.
    ///
    /// `fts5vocab` answers the question directly with a range scan over the term
    /// index, which costs microseconds and stores nothing. This is the cheap
    /// measurement that decides whether to do the expensive work — never the
    /// other way around.
    public func prefixBreadth(_ prefix: String) throws -> Int {
        // The upper bound is the prefix with its last scalar incremented, which
        // is the standard way to express "everything starting with this" as a
        // range. `{` after `z` happens to work for ASCII and nothing else, so it
        // is computed properly instead.
        guard let upper = Self.prefixUpperBound(prefix) else { return 0 }
        return try dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT coalesce(sum(doc), 0) FROM search_vocab
                WHERE term >= ? AND term < ?
                """, arguments: [prefix, upper]) ?? 0
        }
    }

    static func prefixUpperBound(_ prefix: String) -> String? {
        guard let last = prefix.unicodeScalars.last,
              let bumped = Unicode.Scalar(last.value + 1) else { return nil }
        return String(prefix.unicodeScalars.dropLast()) + String(bumped)
    }

    /// Total rows in the text index, so breadth can be judged as a fraction of
    /// the library rather than an absolute number that means something different
    /// on every Mac.
    public func searchIndexRowCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index") ?? 0
        }
    }

    /// One MATCH, several independent top-N lists.
    ///
    /// The search engine wants the best transcript hits, the best on-screen-text
    /// hits and the best filename hits for the same words. Asking three times
    /// meant FTS5 scored and sorted the same matched rows three times over —
    /// 1.11 s + 0.72 s + 0.74 s on a 1.5 M-row index.
    ///
    /// Merging them has a catch worth writing down, because it is not obvious
    /// and it cost a measurement to find. FTS5 has a fast path for exactly
    /// `ORDER BY rank LIMIT n`: it keeps a bounded heap instead of scoring,
    /// materialising and sorting every match. Adding `AND kind IN (…)` defeats
    /// it, because the filter has to read each matched row's content to see what
    /// kind it is. Measured on the same query: 0.07 s bounded and unfiltered,
    /// versus 0.20 s filtered.
    ///
    /// So the fast path is taken as written, over-fetching enough rows to fill
    /// every group, and the split happens here. A group can only come up short
    /// if the scan was truncated — and only then is a second, targeted query
    /// worth paying for. In the ordinary case there is one bounded scan.
    public func textSearch(pattern: String, groups: [[SearchTextKind]],
                           limitPerGroup: Int = 200) throws -> [[TextHit]] {
        var groupOf: [SearchTextKind: Int] = [:]
        for (index, group) in groups.enumerated() {
            for kind in group { groupOf[kind] = index }
        }
        guard !groupOf.isEmpty else { return groups.map { _ in [] } }

        let overFetch = limitPerGroup * groups.count
        var out = [[TextHit]](repeating: [], count: groups.count)
        var scanned = 0

        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT text, assetID, momentID, kind, startSeconds, endSeconds,
                       bm25(search_index, 10.0) AS rank
                FROM search_index
                WHERE search_index MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, overFetch])
            scanned = rows.count
            for row in rows {
                guard let kind = SearchTextKind(rawValue: row["kind"]),
                      let group = groupOf[kind],
                      out[group].count < limitPerGroup else { continue }
                out[group].append(Self.textHit(row, kind: kind))
            }
        }

        // Everything the pattern matches was already seen, so no group is short
        // for want of looking further.
        guard scanned >= overFetch else { return out }

        for (index, group) in groups.enumerated()
        where !group.isEmpty && out[index].count < limitPerGroup {
            out[index] = try textSearch(pattern: pattern, kinds: group, limit: limitPerGroup)
        }
        return out
    }

    private static func textHit(_ row: Row, kind: SearchTextKind) -> TextHit {
        TextHit(
            assetID: row["assetID"],
            momentID: row["momentID"],
            kind: kind,
            startSeconds: row["startSeconds"],
            endSeconds: row["endSeconds"],
            text: row["text"],
            snippet: row["snip"] ?? "",
            score: -(row["rank"] as Double))
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

    // MARK: - Result hydration

    /// Preview paths for exactly these moments, in one query.
    public func previewPaths(momentIDs: [Int64]) throws -> [Int64: String] {
        guard !momentIDs.isEmpty else { return [:] }
        return try dbPool.read { db in
            var out: [Int64: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT momentID, cachePath FROM previews
                WHERE momentID IN (\(databaseQuestionMarks(count: momentIDs.count)))
                """, arguments: StatementArguments(momentIDs))
            for row in rows { out[row["momentID"]] = row["cachePath"] }
            return out
        }
    }

    /// For each (asset, instant), the preview closest in time — in one query.
    ///
    /// A transcript match is a moment of speech and carries no keyframe of its
    /// own, so the useful picture is the frame that was on screen when the words
    /// were said. Answering that per result meant one query per card; a search
    /// showing thirty results issued up to sixty. The correlated subquery below
    /// does the same work in a single round trip, still using the
    /// `(assetID, startSeconds)` index for each lookup.
    public func nearestPreviewPaths(targets: [(assetID: Int64, seconds: Double)]) throws
        -> [Int: String] {
        guard !targets.isEmpty else { return [:] }
        let values = Array(repeating: "(?, ?, ?)", count: targets.count).joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = []
        for (requestID, target) in targets.enumerated() {
            arguments.append(requestID)
            arguments.append(target.assetID)
            arguments.append(target.seconds)
        }
        return try dbPool.read { db in
            var out: [Int: String] = [:]
            // A correlated `LIMIT 1` would read better, but SQLite cannot see an
            // outer CTE column from inside a joined subquery. Ranking with a
            // window function and keeping row 1 per request is the same answer,
            // and still drives the `(assetID, startSeconds)` index.
            let rows = try Row.fetchAll(db, sql: """
                WITH wanted(requestID, assetID, target) AS (VALUES \(values))
                SELECT requestID, cachePath FROM (
                    SELECT w.requestID AS requestID, p.cachePath AS cachePath,
                           row_number() OVER (
                               PARTITION BY w.requestID
                               ORDER BY ABS(m.startSeconds - w.target), m.momentID
                           ) AS position
                    FROM wanted w
                    JOIN moments m ON m.assetID = w.assetID
                    JOIN previews p ON p.momentID = m.momentID
                )
                WHERE position = 1
                """, arguments: StatementArguments(arguments))
            for row in rows {
                if let path: String = row["cachePath"] { out[row["requestID"]] = path }
            }
            return out
        }
    }

    public func volumes(uuids: [String]) throws -> [String: Volume] {
        guard !uuids.isEmpty else { return [:] }
        return try dbPool.read { db in
            let rows = try Volume.filter(uuids.contains(Column("volumeUUID"))).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.volumeUUID, $0) })
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
                SELECT candidate.* FROM jobs AS candidate
                WHERE candidate.state = 'pending'
                  AND candidate.task IN (\(placeholders))
                  AND candidate.attempts < 3
                  AND NOT EXISTS (
                      SELECT 1 FROM jobs AS active
                      WHERE active.assetID = candidate.assetID
                        AND active.state = 'running'
                  )
                ORDER BY candidate.priority, candidate.jobID LIMIT 1
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

    /// Schedules a one-time OCR refresh when the recognition pipeline changes.
    /// Existing moments and embeddings stay intact; only the decoded keyframes
    /// are revisited. A fresh database records the version with zero work, so
    /// new assets rely on the inline OCR done by their visual job.
    @discardableResult
    public func prepareOCRBackfill(version: String) throws -> Int {
        try prepareAnalysisBackfill(
            key: "ocr",
            version: version,
            task: .ocr,
            assetPredicate: "(a.indexedLevels & 2) != 0 AND EXISTS (SELECT 1 FROM moments m WHERE m.assetID = a.assetID)")
    }

    /// Re-runs only assets that already have speech text when timestamp
    /// extraction improves. This replaces minute-wide jumps with fine-grained
    /// chunks without touching files that were never transcribed.
    @discardableResult
    public func prepareTranscriptionBackfill(version: String) throws -> Int {
        try prepareAnalysisBackfill(
            key: "transcription",
            version: version,
            task: .transcribe,
            assetPredicate: "EXISTS (SELECT 1 FROM transcript_chunks t WHERE t.assetID = a.assetID)")
    }

    private func prepareAnalysisBackfill(key: String, version: String, task: JobTask,
                                         assetPredicate: String) throws -> Int {
        try dbPool.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT version FROM analysis_state WHERE key = ?", arguments: [key])
            guard current != version else { return 0 }

            try db.execute(sql: """
                INSERT INTO jobs (assetID, task, state, priority, attempts, lastError, updatedAt)
                SELECT a.assetID, ?, 'pending', ?, 0, NULL, ?
                FROM assets a
                WHERE \(assetPredicate)
                ON CONFLICT(assetID, task) DO UPDATE SET
                    state = 'pending', attempts = 0, lastError = NULL,
                    priority = excluded.priority, updatedAt = excluded.updatedAt
                """, arguments: [task.rawValue, task.defaultPriority, Date()])
            let scheduled = db.changesCount

            try db.execute(sql: """
                INSERT INTO analysis_state (key, version, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    version = excluded.version, updatedAt = excluded.updatedAt
                """, arguments: [key, version, Date()])
            return scheduled
        }
    }

    // MARK: - Models

    public func register(model: ModelRecord) throws {
        try dbPool.write { db in try model.upsert(db) }
    }

    // MARK: - Stats

    public struct Stats: Sendable {
        public var assets = 0
        /// Metadata is Tier 1: the asset can already be found by name, folder,
        /// date or camera even while visual/audio enrichment continues.
        public var searchableAssets = 0
        public var visuallyUnderstoodAssets = 0
        public var transcribedAssets = 0
        public var ocrEnrichedAssets = 0
        public var enrichingAssets = 0
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

            // This runs every time the menu refreshes. One aggregate pass stays
            // cheap on a million-row library; four separate COUNT scans do not.
            if let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS total,
                       coalesce(sum(CASE WHEN (indexedLevels & 1) != 0 THEN 1 ELSE 0 END), 0) AS searchable,
                       coalesce(sum(CASE WHEN (indexedLevels & 2) != 0 THEN 1 ELSE 0 END), 0) AS visual,
                       coalesce(sum(CASE WHEN (indexedLevels & 4) != 0 THEN 1 ELSE 0 END), 0) AS transcribed
                FROM assets
                """) {
                stats.assets = row["total"]
                stats.searchableAssets = row["searchable"]
                stats.visuallyUnderstoodAssets = row["visual"]
                stats.transcribedAssets = row["transcribed"]
            }
            stats.ocrEnrichedAssets = try count(
                "SELECT count(DISTINCT assetID) FROM ocr_texts")
            stats.moments = try count("SELECT count(*) FROM moments")
            stats.embeddings = try count("SELECT count(*) FROM embeddings")
            stats.transcriptChunks = try count("SELECT count(*) FROM transcript_chunks")
            stats.volumesOnline = try count("SELECT count(*) FROM volumes WHERE isOnline = 1")
            stats.volumesOffline = try count("SELECT count(*) FROM volumes WHERE isOnline = 0")
            if let row = try Row.fetchOne(db, sql: """
                SELECT count(DISTINCT CASE WHEN state IN ('pending','running') THEN assetID END) AS enriching,
                       coalesce(sum(CASE WHEN state IN ('pending','running') THEN 1 ELSE 0 END), 0) AS pending,
                       coalesce(sum(CASE WHEN state = 'failed' THEN 1 ELSE 0 END), 0) AS failed
                FROM jobs
                """) {
                stats.enrichingAssets = row["enriching"]
                stats.pendingJobs = row["pending"]
                stats.failedJobs = row["failed"]
            }
            stats.missingLocations = try count("SELECT count(*) FROM locations WHERE availability = 'missing'")
            return stats
        }
    }
}

// MARK: - Helpers

func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
