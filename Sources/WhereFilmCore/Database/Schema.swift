import Foundation
import GRDB

/// The SQLite schema. This is the single source of truth for the whole product:
/// the USearch vector index is *derived* from `embeddings` and can be deleted and
/// rebuilt at any time without losing anything.
public enum Schema {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Volumes are identified by their persistent UUID, never by mount path.
            // macOS is free to remount "Media" as "/Volumes/Media 1"; that must not
            // break a single reference.
            try db.create(table: "volumes") { t in
                t.primaryKey("volumeUUID", .text)
                t.column("name", .text).notNull()
                t.column("fsType", .text)
                t.column("isOnline", .boolean).notNull().defaults(to: false)
                t.column("lastSeenAt", .datetime).notNull()
                t.column("bookmark", .blob)
            }

            try db.create(table: "assets") { t in
                t.autoIncrementedPrimaryKey("assetID")
                t.column("contentKey", .text).notNull().unique()
                t.column("strongKey", .text)
                t.column("mediaType", .text).notNull()
                t.column("durationSeconds", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("createdAt", .datetime)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("indexedLevels", .integer).notNull().defaults(to: 0)
                t.column("displayName", .text).notNull()
                t.column("indexedAt", .datetime).notNull()
            }
            try db.create(index: "idx_assets_strongKey", on: "assets", columns: ["strongKey"])

            // One asset, many possible places it lives. Deleting a location never
            // deletes what we learned about the asset.
            try db.create(table: "locations") { t in
                t.autoIncrementedPrimaryKey("locationID")
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("volumeUUID", .text).notNull()
                    .references("volumes", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime)
                t.column("availability", .text).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.uniqueKey(["volumeUUID", "relativePath"])
            }
            try db.create(index: "idx_locations_asset", on: "locations", columns: ["assetID"])

            try db.create(table: "moments") { t in
                t.autoIncrementedPrimaryKey("momentID")
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("frameHash", .integer)
            }
            try db.create(index: "idx_moments_asset", on: "moments",
                          columns: ["assetID", "startSeconds"])

            // Vectors are stored quantized (int8 + scale) so millions of moments
            // cost gigabytes, not tens of gigabytes. `modelID` is mandatory:
            // embeddings from different models are never compared.
            try db.create(table: "embeddings") { t in
                t.column("momentID", .integer).notNull()
                    .references("moments", onDelete: .cascade)
                t.column("modelID", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("quantization", .text).notNull()
                t.column("scale", .double).notNull().defaults(to: 1.0)
                t.column("vector", .blob).notNull()
                t.primaryKey(["momentID", "modelID"])
            }
            try db.create(index: "idx_embeddings_model", on: "embeddings", columns: ["modelID"])

            try db.create(table: "transcript_chunks") { t in
                t.autoIncrementedPrimaryKey("chunkID")
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double)
                t.column("locale", .text)
            }
            try db.create(index: "idx_transcript_asset", on: "transcript_chunks",
                          columns: ["assetID", "startSeconds"])

            try db.create(table: "ocr_texts") { t in
                t.autoIncrementedPrimaryKey("ocrID")
                t.column("momentID", .integer).notNull()
                    .references("moments", onDelete: .cascade)
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("confidence", .double)
            }

            // Previews are a *budgeted cache*, not storage. A thumbnail per moment
            // for millions of moments would dwarf the vectors themselves.
            try db.create(table: "previews") { t in
                t.primaryKey("momentID", .integer)
                    .references("moments", onDelete: .cascade)
                t.column("cachePath", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_previews_lru", on: "previews", columns: ["lastUsedAt"])

            try db.create(table: "jobs") { t in
                t.autoIncrementedPrimaryKey("jobID")
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("task", .text).notNull()
                t.column("state", .text).notNull()
                t.column("priority", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["assetID", "task"])
            }
            try db.create(index: "idx_jobs_queue", on: "jobs",
                          columns: ["state", "priority", "jobID"])

            try db.create(table: "model_registry") { t in
                t.primaryKey("modelID", .text)
                t.column("kind", .text).notNull()
                t.column("revision", .text)
                t.column("dimensions", .integer).notNull()
                t.column("quantization", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Exact/lexical search: transcripts, on-screen text, filenames, folder
            // names, camera metadata and user notes all in one FTS5 table.
            // `remove_diacritics 2` is what makes "presupuesto" find "presupuestó".
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_index USING fts5(
                    text,
                    assetID UNINDEXED,
                    momentID UNINDEXED,
                    kind UNINDEXED,
                    startSeconds UNINDEXED,
                    endSeconds UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }

        // Records the version of derived analysis, independently of the app
        // version. OCR resolution and transcript timing can improve without
        // invalidating visual embeddings or asking someone to rebuild the
        // entire library from scratch.
        migrator.registerMigration("v2-analysis-state") { db in
            try db.create(table: "analysis_state") { t in
                t.primaryKey("key", .text)
                t.column("version", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}

/// What kind of text a `search_index` row holds — used both for filtering and for
/// telling the user *why* a result matched.
public enum SearchTextKind: String, Sendable, CaseIterable {
    case transcript
    case ocr
    case filename
    case folder
    case metadata
    case note
}
