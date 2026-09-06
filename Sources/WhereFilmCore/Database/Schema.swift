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

        // Coverage stats count distinct assets with OCR. Without this index the
        // menu refresh would scan every OCR row in a large library.
        migrator.registerMigration("v3-coverage-stats") { db in
            try db.create(index: "idx_ocr_asset", on: "ocr_texts", columns: ["assetID"])
        }

        // FTS5's own term dictionary, exposed as a table. Stores nothing: it is
        // a view over the index that already exists, and it is what lets the
        // query planner ask "how many rows would this prefix touch?" before
        // paying to find out the expensive way.
        migrator.registerMigration("v4-search-vocab") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS search_vocab
                USING fts5vocab('search_index', 'row')
                """)
        }

        // Which engine produced a piece of derived text.
        //
        // `embeddings.modelID` has always recorded this for vectors, and the
        // reason is worth repeating for text: macOS 26 is the last release that
        // runs on Intel Macs, which have no neural engine and therefore fall back
        // from `SpeechTranscriber` to `DictationTranscriber`. A library
        // transcribed by the weaker engine should be *findable* later, so it can
        // be redone on better hardware — the same way an old model's embeddings
        // can be reindexed in the background instead of migrated destructively.
        migrator.registerMigration("v5-derivation-provenance") { db in
            try db.alter(table: "transcript_chunks") { table in
                table.add(column: "engine", .text)
            }
            try db.alter(table: "ocr_texts") { table in
                table.add(column: "engine", .text)
            }
        }

        // Scene and object labels from Vision's own classifier.
        //
        // The cheapest recall in the product, and it was simply absent. The only
        // thing that could answer "un pato amarillo" was MobileCLIP-S0, the
        // smallest model in its family and weakest at exactly the concrete nouns
        // people search by. `ClassifyImageRequest` answers from a taxonomy, on a
        // frame that has already been decoded, and returns *text* — which means
        // it lands in FTS5 next to the transcript and the on-screen text, and the
        // query translator makes it work in Spanish without the visual model
        // being involved at all.
        migrator.registerMigration("v6-scene-labels") { db in
            try db.create(table: "labels") { t in
                t.autoIncrementedPrimaryKey("labelID")
                t.column("momentID", .integer).notNull()
                    .references("moments", onDelete: .cascade)
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("identifier", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_labels_moment", on: "labels", columns: ["momentID"])
            try db.create(index: "idx_labels_asset", on: "labels", columns: ["assetID"])
            // Ranking needs to know how common a label is before it can decide
            // what one is worth. Without this index that question is a table scan
            // on every search.
            try db.create(index: "idx_labels_identifier", on: "labels", columns: ["identifier"])
        }

        // People: faces, the clusters they form, and where they appear.
        //
        // This reverses a decision the original plan made deliberately — face
        // recognition was left out of the core because it is biometric data and
        // "el chavo de playera azul" can be answered without knowing who anyone
        // is. That reasoning was right about the cost and wrong about the need:
        // the archive this is built for is full of people who are searched for
        // by name, and "¿dónde aparece Jorge?" is not answerable any other way.
        //
        // Reversing it comes with obligations, and they are structural rather
        // than aspirational: every face vector records the model that produced
        // it so a better model is a background reindex; a name is only ever set
        // by a person; and the whole subtree can be deleted without touching
        // anything else the index knows.
        migrator.registerMigration("v7-people") { db in
            try db.create(table: "people") { t in
                t.autoIncrementedPrimaryKey("personID")
                // NULL until somebody says who this is. An unnamed cluster is
                // still useful — "more of this person" — and still deletable.
                t.column("displayName", .text)
                t.column("isNamed", .boolean).notNull().defaults(to: false)
                t.column("centroid", .blob)
                t.column("faceCount", .integer).notNull().defaults(to: 0)
                t.column("coverFaceID", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "faces") { t in
                t.autoIncrementedPrimaryKey("faceID")
                t.column("momentID", .integer).notNull()
                    .references("moments", onDelete: .cascade)
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("seconds", .double).notNull()
                // Normalised to the frame, origin lower-left, as Vision reports.
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("quality", .double)
                t.column("roll", .double)
                t.column("yaw", .double)
                t.column("pitch", .double)
                t.column("modelID", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("quantization", .text).notNull()
                t.column("scale", .double).notNull().defaults(to: 1.0)
                t.column("vector", .blob).notNull()
                t.column("personID", .integer)
                    .references("people", onDelete: .setNull)
                // 'auto' or 'user'. An automatic pass may move an 'auto' face
                // between clusters; it may never move one a person placed.
                t.column("assignedBy", .text).notNull().defaults(to: "auto")
            }
            try db.create(index: "idx_faces_person", on: "faces", columns: ["personID"])
            try db.create(index: "idx_faces_asset", on: "faces", columns: ["assetID", "seconds"])
            try db.create(index: "idx_faces_model", on: "faces", columns: ["modelID"])

            // What a person corrected, kept forever and separately from what was
            // derived. A consolidation pass reads this before it merges anything.
            try db.create(table: "people_feedback") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("aPersonID", .integer)
                t.column("bPersonID", .integer)
                t.column("faceID", .integer)
                t.column("createdAt", .datetime).notNull()
            }

            // "Jorge apareció en el minuto X" — intervals, not instants.
            try db.create(table: "person_appearances") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personID", .integer).notNull()
                    .references("people", onDelete: .cascade)
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("confidence", .double).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_appearances_person", on: "person_appearances",
                          columns: ["personID", "assetID", "startSeconds"])
            try db.create(index: "idx_appearances_asset", on: "person_appearances",
                          columns: ["assetID", "startSeconds"])

            // Names are searched with typos and without accents. A trigram index
            // finds "Alvares" inside "ÁLVAREZ", which a prefix index cannot, and
            // it is small because it holds only the names a person typed.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE person_names USING fts5(
                    name, personID UNINDEXED, tokenize = 'trigram'
                )
                """)
        }

        // What somebody did with the answers.
        //
        // The channel weights — 0.45 visual, 0.35 transcript, and so on — are a
        // reasonable guess made once, on one machine, about every library that
        // will ever exist. An archive of silent b-roll and an archive of
        // interviews do not want the same numbers, and only one person can say
        // which is which: the one opening the results.
        //
        // Query text is omitted. Hashes still describe usage and are treated as
        // private data: neither usage nor its hashing key belongs in a sidecar.
        migrator.registerMigration("v8-interactions") { db in
            try db.create(table: "interactions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("queryHash", .text).notNull()
                t.column("assetID", .integer)
                t.column("momentID", .integer)
                t.column("action", .text).notNull()
                t.column("rank", .integer)
                t.column("dwellMilliseconds", .integer)
                // The evidence that was on the card, so a preference can be
                // attributed to a channel rather than to a file.
                t.column("channels", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_interactions_time", on: "interactions",
                          columns: ["createdAt"])
        }

        migrator.registerMigration("v9-usage-state") { db in
            try db.execute(sql: """
                CREATE TABLE usage_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    revision INTEGER NOT NULL DEFAULT 0,
                    enabled INTEGER NOT NULL DEFAULT 0,
                    queryKey BLOB NOT NULL DEFAULT (randomblob(32))
                );
                INSERT INTO usage_state(id) VALUES (1);
                CREATE TRIGGER interactions_insert AFTER INSERT ON interactions BEGIN
                    UPDATE usage_state SET revision = revision + 1 WHERE id = 1;
                END;
                CREATE TRIGGER interactions_delete AFTER DELETE ON interactions BEGIN
                    UPDATE usage_state SET revision = revision + 1 WHERE id = 1;
                END;
                """)
        }

        // Voices: who spoke, and when.
        //
        // The mirror of faces, and the half that answers a different question.
        // A person who is talking is very often not on screen — an interviewer,
        // a narrator, somebody behind the camera — so "¿dónde habla Jorge?" and
        // "¿dónde sale Jorge?" have different answers, and the transcript alone
        // knows neither.
        //
        // Same rules as faces, for the same reason: a voice print is biometric,
        // every vector records its model, and `forgetEveryone()` takes these
        // tables with it.
        migrator.registerMigration("v9-voices") { db in
            try db.create(table: "voices") { t in
                t.autoIncrementedPrimaryKey("voiceID")
                // Filled in when a voice cluster is linked to a face cluster, or
                // named directly. NULL means "somebody, consistently".
                t.column("personID", .integer)
                    .references("people", onDelete: .setNull)
                t.column("centroid", .blob)
                t.column("segmentCount", .integer).notNull().defaults(to: 0)
                t.column("modelID", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "voice_segments") { t in
                t.autoIncrementedPrimaryKey("segmentID")
                t.column("assetID", .integer).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                // The speaker label the diarizer used *within this file*. It
                // means nothing across files, which is exactly why clustering
                // over the embeddings exists.
                t.column("localSpeaker", .text).notNull()
                t.column("voiceID", .integer)
                    .references("voices", onDelete: .setNull)
                t.column("modelID", .text).notNull()
                t.column("dimensions", .integer).notNull().defaults(to: 0)
                t.column("quantization", .text).notNull().defaults(to: "int8")
                t.column("scale", .double).notNull().defaults(to: 1.0)
                t.column("vector", .blob)
                t.column("confidence", .double)
            }
            try db.create(index: "idx_voice_segments_asset", on: "voice_segments",
                          columns: ["assetID", "startSeconds"])
            try db.create(index: "idx_voice_segments_voice", on: "voice_segments",
                          columns: ["voiceID"])
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
    /// A scene or object label from Vision's classifier. Text, but describing
    /// what the frame *is*, not what it says — so it is matched against the
    /// English half of a query rather than the spoken half.
    case label
}
