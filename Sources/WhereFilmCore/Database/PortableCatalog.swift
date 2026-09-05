import Foundation
import CryptoKit
import GRDB

/// A portable volume snapshot. SQLite remains canonical; ANN files can always
/// be rebuilt from these vectors without opening any original media.
public enum PortableCatalog {
    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }
    public struct Manifest: Codable, Sendable {
        public let format: Int
        public let volumeUUID: String
        public let createdAt: Date
        public let assets: Int
        public let moments: Int
        public let includesBiometrics: Bool
        public let sha256: String
    }
    public struct ImportReport: Codable, Sendable {
        public var addedAssets = 0
        public var existingAssets = 0
        public var addedMoments = 0
        public var addedLocations = 0
    }

    /// Writes to a fresh sibling directory, then atomically renames it. A
    /// selected-table snapshot never copies private pages into the export.
    public static func export(store: IndexStore, volumeUUID: String, to destination: URL) throws -> Manifest {
        let fm = FileManager.default
        guard destination.pathExtension == "wfindex" else { throw Failure.invalid("Use a .wfindex directory.") }
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.invalid("Destination already exists; choose a new snapshot name.") }
        guard try store.volume(uuid: volumeUUID) != nil else { throw Failure.invalid("Unknown volume UUID.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".wf-export-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let databaseURL = staging.appendingPathComponent("index.sqlite")
        let snapshot = try IndexStore(url: databaseURL)
        try snapshot.dbPool.writeWithoutTransaction { db in
            try attach(store.dbPool.path, to: db)
            defer { try? db.execute(sql: "DETACH DATABASE incoming") }
            try db.inTransaction {
                // No bookmarks or online state cross machines.
                try db.execute(sql: """
                    INSERT INTO volumes(volumeUUID, name, fsType, isOnline, lastSeenAt)
                    SELECT volumeUUID, name, fsType, 0, lastSeenAt FROM incoming.volumes WHERE volumeUUID = ?;
                    """, arguments: [volumeUUID])
                try db.execute(sql: """
                    INSERT INTO assets SELECT a.* FROM incoming.assets a
                    WHERE EXISTS (SELECT 1 FROM incoming.locations l WHERE l.assetID = a.assetID AND l.volumeUUID = ?)
                    """, arguments: [volumeUUID])
                try db.execute(sql: "UPDATE assets SET indexedLevels = indexedLevels & ~8")
                try db.execute(sql: """
                    INSERT INTO locations SELECT * FROM incoming.locations WHERE volumeUUID = ?;
                    UPDATE locations SET availability = CASE WHEN availability = 'online' THEN 'offline' ELSE availability END;
                    INSERT INTO moments SELECT m.* FROM incoming.moments m JOIN assets a USING(assetID);
                    INSERT INTO embeddings SELECT e.* FROM incoming.embeddings e JOIN moments m USING(momentID);
                    INSERT INTO transcript_chunks SELECT t.* FROM incoming.transcript_chunks t JOIN assets a USING(assetID);
                    INSERT INTO ocr_texts SELECT o.* FROM incoming.ocr_texts o JOIN moments m USING(momentID);
                    INSERT INTO labels SELECT l.* FROM incoming.labels l JOIN moments m USING(momentID);
                    INSERT INTO analysis_state SELECT * FROM incoming.analysis_state WHERE key IN ('ocr', 'transcription');
                    INSERT INTO model_registry SELECT r.* FROM incoming.model_registry r
                        WHERE r.modelID IN (SELECT DISTINCT modelID FROM embeddings);
                    """, arguments: [volumeUUID])
                // Copy only the selected asset's searchable content. Folder rows
                // are rebuilt from this volume, never from its other locations.
                try db.execute(sql: """
                    INSERT INTO search_index(text, assetID, momentID, kind, startSeconds, endSeconds)
                    SELECT s.text, s.assetID, s.momentID, s.kind, s.startSeconds, s.endSeconds
                    FROM incoming.search_index s JOIN assets a ON a.assetID = s.assetID
                    WHERE s.kind IN ('filename', 'metadata', 'note', 'transcript', 'ocr', 'label')
                      AND (s.momentID IS NULL OR s.momentID IN (SELECT momentID FROM moments));
                    INSERT INTO search_index(text, assetID, kind, startSeconds, endSeconds)
                    SELECT relativePath, assetID, 'folder', 0, 0 FROM locations;
                    """)
                return .commit
            }
            try db.execute(sql: "PRAGMA main.wal_checkpoint(TRUNCATE)")
        }
        let stats = try snapshot.stats()
        try snapshot.dbPool.close()
        let manifest = Manifest(format: 1, volumeUUID: volumeUUID, createdAt: Date(),
                                assets: stats.assets, moments: stats.moments,
                                includesBiometrics: false, sha256: try checksum(databaseURL))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        return manifest
    }

    public static func inspect(_ directory: URL) throws -> Manifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let dbURL = directory.appendingPathComponent("index.sqlite")
        for url in [directory, manifestURL, dbURL] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.invalid("Sidecar entries must not be symbolic links.") }
        }
        let bytes = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes < 65_536 else { throw Failure.invalid("Invalid manifest size.") }
        // An export is a closed SQLite snapshot. A live WAL could otherwise
        // override pages without being covered by the manifest checksum.
        for suffix in ["-wal", "-journal"] {
            let companion = URL(fileURLWithPath: dbURL.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path),
               (try companion.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 {
                throw Failure.invalid("Sidecar has an active SQLite journal; export a closed snapshot first.")
            }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == 1, !manifest.includesBiometrics, !manifest.volumeUUID.isEmpty,
              manifest.assets >= 0, manifest.moments >= 0 else { throw Failure.invalid("Unsupported sidecar format.") }
        guard try checksum(dbURL) == manifest.sha256 else { throw Failure.invalid("Sidecar checksum mismatch; no data imported.") }
        return manifest
    }

    /// Merge by content identity, never by the other Mac's numeric IDs. Existing
    /// analysis and corrections win. New data is one destination transaction;
    /// cancellation or an invalid path rolls back the whole import.
    public static func importCatalog(from directory: URL, into store: IndexStore) throws -> ImportReport {
        let manifest = try inspect(directory)
        return try store.dbPool.writeWithoutTransaction { db in
            try attach(directory.appendingPathComponent("index.sqlite").path, to: db)
            defer {
                try? db.execute(sql: "DROP TABLE IF EXISTS temp.wf_asset_map; DROP TABLE IF EXISTS temp.wf_moment_map")
                try? db.execute(sql: "DETACH DATABASE incoming")
            }
            var report = ImportReport()
            try db.inTransaction {
                guard try String.fetchOne(db, sql: "PRAGMA incoming.quick_check") == "ok",
                      try Row.fetchOne(db, sql: "PRAGMA incoming.foreign_key_check") == nil else {
                    throw Failure.invalid("Sidecar database is inconsistent.")
                }
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM incoming.volumes") == 1,
                      try String.fetchOne(db, sql: "SELECT volumeUUID FROM incoming.volumes") == manifest.volumeUUID,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM incoming.assets") == manifest.assets,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM incoming.moments") == manifest.moments else {
                    throw Failure.invalid("Sidecar counts or volume do not match its manifest.")
                }
                guard try Int.fetchOne(db, sql: """
                    SELECT 1 FROM incoming.embeddings WHERE dimensions < 1 OR dimensions > 16384
                       OR quantization NOT IN ('int8', 'float32')
                       OR length(vector) != dimensions * CASE WHEN quantization = 'float32' THEN 4 ELSE 1 END
                       OR scale <= 0 LIMIT 1
                    """) == nil else { throw Failure.invalid("Invalid sidecar embedding format.") }
                guard try Row.fetchOne(db, sql: """
                    SELECT modelID FROM (
                        SELECT modelID, dimensions FROM incoming.embeddings
                        UNION ALL SELECT modelID, dimensions FROM embeddings
                    ) GROUP BY modelID HAVING min(dimensions) != max(dimensions) LIMIT 1
                    """) == nil else { throw Failure.invalid("Embedding model dimensions conflict with the local catalog.") }
                if try Int.fetchOne(db, sql: "SELECT count(*) FROM assets") == 0 {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO analysis_state SELECT * FROM incoming.analysis_state
                        WHERE key IN ('ocr', 'transcription')
                        """)
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO volumes(volumeUUID, name, fsType, isOnline, lastSeenAt)
                    SELECT volumeUUID, name, fsType, 0, lastSeenAt FROM incoming.volumes;
                    CREATE TEMP TABLE wf_asset_map(oldID INTEGER PRIMARY KEY, newID INTEGER NOT NULL, importAnalysis INTEGER NOT NULL);
                    CREATE TEMP TABLE wf_moment_map(oldID INTEGER PRIMARY KEY, newID INTEGER NOT NULL);
                    """)
                let assets = try Asset.fetchCursor(db, sql: "SELECT * FROM incoming.assets ORDER BY assetID")
                while var asset = try assets.next() {
                    try Task.checkCancellation()
                    guard let oldID = asset.assetID, oldID > 0 else { throw Failure.invalid("Invalid asset identity.") }
                    let existing = try Asset.fetchOne(db, sql: "SELECT * FROM assets WHERE contentKey = ?", arguments: [asset.contentKey])
                    let takeAnalysis: Bool
                    if let existing {
                        if let a = asset.strongKey, let b = existing.strongKey, a != b {
                            throw Failure.invalid("Content identity conflict; local data preserved.")
                        }
                        asset.assetID = existing.assetID
                        // Preserve any existing analysis. A metadata-only local
                        // entry can still receive a fully analyzed snapshot.
                        takeAnalysis = try Int.fetchOne(db, sql: """
                            SELECT EXISTS(SELECT 1 FROM moments WHERE assetID = ?)
                                OR EXISTS(SELECT 1 FROM transcript_chunks WHERE assetID = ?)
                                OR EXISTS(SELECT 1 FROM jobs WHERE assetID = ? AND state = 'running')
                            """, arguments: [existing.assetID, existing.assetID, existing.assetID]) == 0
                        report.existingAssets += 1
                    } else {
                        asset.assetID = nil
                        asset.indexedLevels.remove(.deep)
                        try asset.insert(db)
                        takeAnalysis = true
                        report.addedAssets += 1
                    }
                    try db.execute(sql: "INSERT INTO wf_asset_map VALUES (?, ?, ?)", arguments: [oldID, asset.assetID, takeAnalysis])
                    if takeAnalysis {
                        try db.execute(sql: "UPDATE assets SET indexedLevels = indexedLevels | ? WHERE assetID = ?",
                                       arguments: [asset.indexedLevels.rawValue & ~8, asset.assetID])
                    }
                }
                let locations = try Location.fetchCursor(db, sql: """
                    SELECT l.* FROM incoming.locations l JOIN wf_asset_map a ON a.oldID = l.assetID
                    """)
                while var location = try locations.next() {
                    try Task.checkCancellation()
                    guard location.volumeUUID == manifest.volumeUUID, validRelativePath(location.relativePath) else {
                        throw Failure.invalid("Invalid sidecar media path; no data imported.")
                    }
                    let newID = try Int64.fetchOne(db, sql: "SELECT newID FROM wf_asset_map WHERE oldID = ?", arguments: [location.assetID])!
                    if let existing = try Location.fetchOne(db, sql: "SELECT * FROM locations WHERE volumeUUID = ? AND relativePath = ?",
                                                           arguments: [location.volumeUUID, location.relativePath]) {
                        guard existing.assetID == newID else { throw Failure.invalid("A sidecar path refers to different local content; no data imported.") }
                        continue
                    }
                    location.locationID = nil
                    location.assetID = newID
                    if location.availability == .online { location.availability = .offline }
                    try location.insert(db)
                    report.addedLocations += 1
                }
                let moments = try Moment.fetchCursor(db, sql: """
                    SELECT m.* FROM incoming.moments m JOIN wf_asset_map a ON a.oldID = m.assetID WHERE a.importAnalysis = 1
                    ORDER BY m.momentID
                    """)
                while var moment = try moments.next() {
                    try Task.checkCancellation()
                    guard moment.startSeconds.isFinite, moment.endSeconds.isFinite,
                          moment.startSeconds >= 0, moment.endSeconds >= moment.startSeconds else {
                        throw Failure.invalid("Invalid sidecar timecode.")
                    }
                    guard let oldID = moment.momentID, oldID > 0 else { throw Failure.invalid("Invalid moment identity.") }
                    moment.assetID = try Int64.fetchOne(db, sql: "SELECT newID FROM wf_asset_map WHERE oldID = ?", arguments: [moment.assetID])!
                    moment.momentID = nil
                    try moment.insert(db)
                    try db.execute(sql: "INSERT INTO wf_moment_map VALUES (?, ?)", arguments: [oldID, moment.momentID])
                    report.addedMoments += 1
                }
                try db.execute(sql: """
                    INSERT INTO embeddings(momentID, modelID, dimensions, quantization, scale, vector)
                    SELECT m.newID, e.modelID, e.dimensions, e.quantization, e.scale, e.vector
                    FROM incoming.embeddings e JOIN wf_moment_map m ON m.oldID = e.momentID;
                    INSERT INTO transcript_chunks(assetID, startSeconds, endSeconds, text, confidence, locale, engine)
                    SELECT a.newID, t.startSeconds, t.endSeconds, t.text, t.confidence, t.locale, t.engine
                    FROM incoming.transcript_chunks t JOIN wf_asset_map a ON a.oldID = t.assetID WHERE a.importAnalysis = 1;
                    INSERT INTO ocr_texts(momentID, assetID, text, confidence, engine)
                    SELECT m.newID, a.newID, o.text, o.confidence, o.engine FROM incoming.ocr_texts o
                    JOIN wf_moment_map m ON m.oldID = o.momentID JOIN wf_asset_map a ON a.oldID = o.assetID;
                    INSERT INTO labels(momentID, assetID, identifier, confidence, source)
                    SELECT m.newID, a.newID, l.identifier, l.confidence, l.source FROM incoming.labels l
                    JOIN wf_moment_map m ON m.oldID = l.momentID JOIN wf_asset_map a ON a.oldID = l.assetID;
                    INSERT OR IGNORE INTO model_registry SELECT * FROM incoming.model_registry;
                    DELETE FROM search_index WHERE assetID IN (SELECT newID FROM wf_asset_map WHERE importAnalysis = 1)
                        AND kind NOT IN ('filename', 'folder', 'metadata', 'note');
                    INSERT INTO search_index(text, assetID, momentID, kind, startSeconds, endSeconds)
                    SELECT s.text, a.newID, m.newID, s.kind, s.startSeconds, s.endSeconds
                    FROM incoming.search_index s JOIN wf_asset_map a ON a.oldID = s.assetID
                    LEFT JOIN wf_moment_map m ON m.oldID = s.momentID
                    WHERE a.importAnalysis = 1 AND s.kind IN ('filename', 'folder', 'metadata', 'note', 'transcript', 'ocr', 'label')
                      AND (s.kind NOT IN ('filename', 'folder', 'metadata', 'note') OR NOT EXISTS (
                        SELECT 1 FROM search_index local WHERE local.assetID = a.newID AND local.kind = s.kind))
                      AND (s.momentID IS NULL OR m.newID IS NOT NULL);
                    DELETE FROM search_index WHERE kind = 'filename' AND assetID IN (SELECT newID FROM wf_asset_map WHERE importAnalysis = 1);
                    INSERT INTO search_index(text, assetID, kind, startSeconds, endSeconds)
                    SELECT displayName, assetID, 'filename', 0, 0 FROM assets
                    WHERE assetID IN (SELECT newID FROM wf_asset_map WHERE importAnalysis = 1);
                    DELETE FROM jobs WHERE state != 'running'
                      AND assetID IN (SELECT newID FROM wf_asset_map WHERE importAnalysis = 1)
                      AND ((task = 'visual' AND EXISTS(SELECT 1 FROM moments m JOIN embeddings e USING(momentID) WHERE m.assetID = jobs.assetID))
                        OR (task = 'ocr' AND EXISTS(SELECT 1 FROM ocr_texts o WHERE o.assetID = jobs.assetID))
                        OR (task = 'transcribe' AND EXISTS(SELECT 1 FROM transcript_chunks t WHERE t.assetID = jobs.assetID)));
                    """)
                // Rebuilding ANN is derived work, never re-analysis of media.
                // Indexer/search can use SQLite immediately while it is rebuilt.
                return .commit
            }
            return report
        }
    }

    public static func checksum(_ url: URL) throws -> String {
        try BackgroundIO.run {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func attach(_ path: String, to db: Database) throws {
        var url = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        try db.execute(sql: "ATTACH DATABASE ? AS incoming", arguments: [url.string!])
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains("..")
    }
}
