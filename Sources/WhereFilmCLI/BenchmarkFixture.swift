import Foundation
import ArgumentParser
import GRDB
import WhereFilmCore
import WhereFilmML

// A library big enough to have an opinion.
//
// Every latency number this project has published so far came from a fixture of
// nine vectors and one transcript chunk. At that size SQLite answers from a
// single page and HNSW never leaves its entry node, so the measurements say
// almost nothing about the archive the product is actually for. This command
// builds a catalog with hundreds of thousands of moments *without* decoding a
// single frame, which is what makes scaling behaviour observable in seconds
// rather than days.
//
// What is synthetic and what is real matters, so it is stated plainly:
//
//   real      — the schema, the FTS5 index, the int8 vector codec, the HNSW
//               graph, every query path under measurement.
//   synthetic — the pixels. Embeddings are constructed to sit at a chosen cosine
//               similarity from a *real* MobileCLIP text vector, so the
//               distribution of scores against a real query is realistic even
//               though no photograph exists.
//
// Consequence, stated once and honoured everywhere: this fixture measures
// latency, memory and scaling. It must never be used to claim recall, ranking
// quality or accuracy — those need real media.

struct BenchmarkFixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench-fixture",
        abstract: "Generate a large synthetic catalog for latency and scaling measurement.",
        discussion: """
            Latency only. The vectors are constructed, not observed, so recall and \
            ranking numbers taken from this fixture are meaningless.
            """,
        shouldDisplay: false)

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .long, help: "How many assets to synthesize.")
    var assets = 20_000

    @Option(name: .long, help: "Average moments per video asset.")
    var momentsPerVideo = 12

    @Option(name: .long, help: "Fraction of assets that are photographs.")
    var photoFraction = 0.6

    @Option(name: .long, help: "Cap transcript chunks per video. Lower values shrink the fixture on a small disk.")
    var maxTranscriptChunks = 180

    @Option(name: .long, help: "Deterministic seed.")
    var seed: UInt64 = 20_260_902

    @Option(name: .long, help: "MobileCLIP variant whose text space the vectors sit in.")
    var model = "s0"

    func run() async throws {
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'.")
        }
        let store = try storeOptions.makeStore()
        var random = SplitMix64(seed: seed)

        print("Encoding \(BenchmarkCorpus.scenes.count) real text centroids with \(variant.modelID)…")
        let encoder = try MobileCLIPTextEncoder(variant: variant)
        let centroids = try BenchmarkCorpus.scenes.map { try encoder.encode($0.phrase) }

        let started = Date()
        var generator = FixtureGenerator(
            variant: variant, centroids: centroids,
            assetCount: assets, momentsPerVideo: momentsPerVideo,
            photoFraction: photoFraction, maxTranscriptChunks: maxTranscriptChunks,
            random: random)
        let report = try generator.write(into: store)
        random = generator.random

        print("""

            \(report.assets) assets · \(report.moments) moments · \(report.embeddings) embeddings
            \(report.transcriptChunks) transcript chunks · \(report.ocrRows) OCR rows
            \(report.searchRows) FTS rows · \(report.previews) preview rows
            built in \(String(format: "%.1f", Date().timeIntervalSince(started)))s

            Next: wherefilm rebuild-index --database <db>
            """)
    }
}

// MARK: - Corpus

/// The vocabulary the synthetic library is written in.
///
/// Small on purpose. What matters for measurement is the *shape* of the term
/// distribution — a handful of words in most rows, a long tail in almost none —
/// because that is what decides whether an FTS5 MATCH touches a thousand rows or
/// a million.
enum BenchmarkCorpus {
    struct Scene {
        let phrase: String
        /// Spanish words that appear in the dialogue of assets showing this scene.
        let spoken: [String]
    }

    static let scenes: [Scene] = [
        .init(phrase: "a man wearing a blue shirt in an interview", spoken: ["presupuesto", "entrevista", "camisa"]),
        .init(phrase: "a woman with pink headphones at a desk", spoken: ["audifonos", "grabacion", "cabina"]),
        .init(phrase: "a red car parked on a city street", spoken: ["carro", "calle", "trafico"]),
        .init(phrase: "a sunset over the ocean", spoken: ["atardecer", "playa", "mar"]),
        .init(phrase: "snow covered mountains under a clear sky", spoken: ["montana", "nieve", "camino"]),
        .init(phrase: "a plate of food on a wooden table", spoken: ["comida", "cocina", "receta"]),
        .init(phrase: "a crowd at an outdoor concert", spoken: ["concierto", "publico", "musica"]),
        .init(phrase: "a dog running on green grass", spoken: ["perro", "parque", "correr"]),
        .init(phrase: "a person typing on a laptop computer", spoken: ["computadora", "proyecto", "trabajo"]),
        .init(phrase: "a whiteboard covered in diagrams", spoken: ["pizarra", "diagrama", "reunion"]),
        .init(phrase: "children playing in a school yard", spoken: ["ninos", "escuela", "juego"]),
        .init(phrase: "a bridge over a river at night", spoken: ["puente", "rio", "noche"]),
        .init(phrase: "a market stall full of fruit", spoken: ["mercado", "fruta", "vendedor"]),
        .init(phrase: "a camera on a tripod in a studio", spoken: ["camara", "estudio", "tripode"]),
        .init(phrase: "two people shaking hands in an office", spoken: ["oficina", "acuerdo", "cliente"]),
        .init(phrase: "an aerial view of a forest", spoken: ["bosque", "dron", "vista"]),
    ]

    /// Filler that appears everywhere, which is exactly the point: a query term
    /// that matches 30% of the library is the case FTS5 has to survive.
    static let filler = [
        "entonces", "nosotros", "proyecto", "tiempo", "gracias", "vamos",
        "porque", "cuando", "tambien", "hacer", "puede", "todo", "bueno",
        "ahora", "aqui", "despues", "primero", "manera", "cosas", "parte",
    ]

    static let folders = [
        "CLIENT_A/DAY_01", "CLIENT_A/DAY_02", "CLIENT_B/INTERVIEWS",
        "CLIENT_B/BROLL", "ARCHIVE/2024", "ARCHIVE/2025", "PERSONAL/VIAJES",
        "PERSONAL/FAMILIA", "STOCK/AERIAL", "STOCK/CITY",
    ]

    static let cameras = ["Sony FX3", "Canon R5", "iPhone 15 Pro", "BMPCC 6K", "DJI Mavic 3"]
}


/// Writes one FTS5 row. Deliberately a local copy rather than widening
/// `IndexStore`'s API: a benchmark tool is not a reason to make an internal
/// detail public.
func indexText(_ db: Database, text: String, assetID: Int64, momentID: Int64?,
               kind: SearchTextKind, start: Double, end: Double) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try db.execute(sql: """
        INSERT INTO search_index (text, assetID, momentID, kind, startSeconds, endSeconds)
        VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [trimmed, assetID, momentID, kind.rawValue, start, end])
}

// MARK: - Generation

/// Deterministic, seedable, and fast enough to fill a million rows.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ lower: Double, _ upper: Double) -> Double {
        lower + (Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)) * (upper - lower)
    }

    /// Box–Muller, because clustered data needs a bell curve, not a box.
    mutating func gaussian() -> Double {
        let u1 = max(uniform(0, 1), 1e-12)
        let u2 = uniform(0, 1)
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}

struct FixtureGenerator {
    struct Report {
        var assets = 0
        var moments = 0
        var embeddings = 0
        var transcriptChunks = 0
        var ocrRows = 0
        var searchRows = 0
        var previews = 0
    }

    let variant: MobileCLIPVariant
    let centroids: [[Float]]
    let assetCount: Int
    let momentsPerVideo: Int
    let photoFraction: Double
    let maxTranscriptChunks: Int
    var random: SplitMix64

    /// A vector at a chosen cosine similarity from `centroid`.
    ///
    /// The construction is exact rather than approximate: take the centroid,
    /// take a random direction, remove the centroid component from it, and
    /// recombine with weights `t` and `sqrt(1 - t²)`. The result has cosine `t`
    /// with the centroid by definition, which is what lets the fixture place
    /// matches inside MobileCLIP's real 0.14–0.30 band and non-matches below it
    /// instead of hoping random noise lands somewhere plausible.
    mutating func vector(near centroid: [Float], similarity t: Double) -> [Float] {
        let n = centroid.count
        var noise = [Float](repeating: 0, count: n)
        for i in 0..<n { noise[i] = Float(random.gaussian()) }

        var projection: Float = 0
        for i in 0..<n { projection += noise[i] * centroid[i] }
        for i in 0..<n { noise[i] -= projection * centroid[i] }

        var norm: Float = 0
        for i in 0..<n { norm += noise[i] * noise[i] }
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return centroid }

        let a = Float(t)
        let b = Float((1 - t * t).squareRoot()) / norm
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = a * centroid[i] + b * noise[i] }
        return VectorCodec.normalized(out)
    }

    mutating func sentence(scene: BenchmarkCorpus.Scene, words: Int) -> String {
        var parts: [String] = []
        for _ in 0..<words {
            if random.uniform(0, 1) < 0.28 {
                parts.append(scene.spoken[Int(random.next() % UInt64(scene.spoken.count))])
            } else {
                parts.append(BenchmarkCorpus.filler[Int(random.next() % UInt64(BenchmarkCorpus.filler.count))])
            }
        }
        return parts.joined(separator: " ")
    }

    mutating func write(into store: IndexStore) throws -> Report {
        var report = Report()
        let volumeUUID = "BENCH-0000-0000-0000-000000000001"
        let modelID = variant.modelID
        let now = Date()

        // One real file on disk so the preview hydration path does actual
        // filesystem work rather than short-circuiting on a missing file.
        let previewFile = AppPaths.previews.appendingPathComponent("bench-placeholder.jpg")
        if !FileManager.default.fileExists(atPath: previewFile.path) {
            try FileManager.default.createDirectory(
                at: AppPaths.previews, withIntermediateDirectories: true)
            try Data(repeating: 0xFF, count: 2_048).write(to: previewFile)
        }

        try store.upsertVolume(Volume(volumeUUID: volumeUUID, name: "Benchmark",
                                      fsType: "apfs", isOnline: true, lastSeenAt: now))

        // Chunked transactions. One transaction for a million rows holds a write
        // lock for the whole run and balloons the WAL; one per row pays fsync
        // bookkeeping 20,000 times. Batches of 500 assets is the middle.
        let batchSize = 500
        var index = 0
        var copy = self

        while index < assetCount {
            let upper = min(index + batchSize, assetCount)
            try store.dbPool.write { db in
                for assetIndex in index..<upper {
                    let sceneIndex = Int(copy.random.next() % UInt64(BenchmarkCorpus.scenes.count))
                    let scene = BenchmarkCorpus.scenes[sceneIndex]
                    let isPhoto = copy.random.uniform(0, 1) < copy.photoFraction
                    let folder = BenchmarkCorpus.folders[
                        Int(copy.random.next() % UInt64(BenchmarkCorpus.folders.count))]
                    let name = isPhoto
                        ? String(format: "IMG_%05d.heic", assetIndex)
                        : String(format: "%@_%05d.mov", ["INTERVIEW", "BROLL", "TOMA"][sceneIndex % 3], assetIndex)
                    let duration = isPhoto ? nil : copy.random.uniform(8, 3_600)

                    try db.execute(sql: """
                        INSERT INTO assets (contentKey, strongKey, mediaType, durationSeconds,
                                            width, height, createdAt, cameraMake, cameraModel,
                                            indexedLevels, displayName, indexedAt)
                        VALUES (?, NULL, ?, ?, 1920, 1080, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            "bench-\(assetIndex)",
                            isPhoto ? MediaType.image.rawValue : MediaType.video.rawValue,
                            duration,
                            now.addingTimeInterval(-copy.random.uniform(0, 63_072_000)),
                            "Benchmark",
                            BenchmarkCorpus.cameras[Int(copy.random.next() % UInt64(BenchmarkCorpus.cameras.count))],
                            (IndexLevels.metadata.union(.visual).union(.spoken)).rawValue,
                            name, now,
                        ])
                    let assetID = db.lastInsertedRowID
                    report.assets += 1

                    try db.execute(sql: """
                        INSERT INTO locations (assetID, volumeUUID, relativePath, fileSize,
                                               modifiedAt, availability, lastSeenAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [assetID, volumeUUID, "\(folder)/\(name)",
                                         Int64(copy.random.uniform(2_000_000, 40_000_000_000)),
                                         now, Availability.online.rawValue, now])

                    try indexText(db, text: name, assetID: assetID, momentID: nil,
                                             kind: .filename, start: 0, end: 0)
                    try indexText(db, text: folder, assetID: assetID, momentID: nil,
                                             kind: .folder, start: 0, end: 0)
                    report.searchRows += 2

                    // Only a slice of the library is actually *about* each scene.
                    // The rest sits below the similarity floor, which is what
                    // makes the floor do real work during measurement.
                    let isRelevant = copy.random.uniform(0, 1) < 0.06
                    let momentCount = isPhoto ? 1 : max(1, Int(copy.random.uniform(
                        Double(copy.momentsPerVideo) * 0.4, Double(copy.momentsPerVideo) * 1.6)))

                    var pairs: [(Int64, [Float])] = []
                    pairs.reserveCapacity(momentCount)
                    for momentIndex in 0..<momentCount {
                        let start = isPhoto ? 0 : Double(momentIndex) * (duration ?? 60) / Double(momentCount)
                        let end = isPhoto ? 0 : start + 10
                        try db.execute(sql: """
                            INSERT INTO moments (assetID, startSeconds, endSeconds, frameHash)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [assetID, start, end, Int64(bitPattern: copy.random.next())])
                        let momentID = db.lastInsertedRowID
                        report.moments += 1

                        let similarity = isRelevant
                            ? copy.random.uniform(0.17, 0.33)
                            : copy.random.uniform(0.01, 0.12)
                        pairs.append((momentID, copy.vector(near: copy.centroids[sceneIndex],
                                                            similarity: similarity)))

                        // Previews are a budgeted cache in production, so only a
                        // fraction of moments have one here too.
                        if copy.random.uniform(0, 1) < 0.35 {
                            try db.execute(sql: """
                                INSERT INTO previews (momentID, cachePath, bytes, lastUsedAt, pinned)
                                VALUES (?, ?, ?, ?, 0)
                                """, arguments: [momentID, previewFile.path, 2_048, now])
                            report.previews += 1
                        }

                        // On-screen text on a minority of frames, as in real footage.
                        if copy.random.uniform(0, 1) < 0.12 {
                            let text = copy.sentence(scene: scene, words: 4)
                            try db.execute(sql: """
                                INSERT INTO ocr_texts (momentID, assetID, text, confidence)
                                VALUES (?, ?, ?, 0.9)
                                """, arguments: [momentID, assetID, text])
                            try indexText(db, text: text, assetID: assetID,
                                                     momentID: momentID, kind: .ocr,
                                                     start: start, end: end)
                            report.ocrRows += 1
                            report.searchRows += 1
                        }
                    }

                    for (momentID, vector) in pairs {
                        let (data, scale) = VectorCodec.encode(vector, as: .int8)
                        try db.execute(sql: """
                            INSERT INTO embeddings (momentID, modelID, dimensions, quantization, scale, vector)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [momentID, modelID, vector.count,
                                             VectorQuantization.int8.rawValue, scale, data])
                        report.embeddings += 1
                    }

                    // Dialogue, for videos only. Silence is the honest default
                    // for a photograph.
                    if !isPhoto {
                        let chunks = max(2, Int((duration ?? 60) / 20))
                        for chunkIndex in 0..<min(chunks, copy.maxTranscriptChunks) {
                            let start = Double(chunkIndex) * 20
                            let text = copy.sentence(scene: scene, words: 12)
                            try db.execute(sql: """
                                INSERT INTO transcript_chunks (assetID, startSeconds, endSeconds,
                                                               text, confidence, locale)
                                VALUES (?, ?, ?, ?, 0.9, 'es-ES')
                                """, arguments: [assetID, start, start + 20, text])
                            try indexText(db, text: text, assetID: assetID,
                                                     momentID: nil, kind: .transcript,
                                                     start: start, end: start + 20)
                            report.transcriptChunks += 1
                            report.searchRows += 1
                        }
                    }
                }
            }
            index = upper
            FileHandle.standardError.write(
                Data("  \(index)/\(assetCount) assets · \(report.moments) moments\r".utf8))
        }

        self = copy
        try store.dbPool.write { db in
            try db.execute(sql: "INSERT INTO search_index(search_index) VALUES('optimize')")
        }
        try store.dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "ANALYZE")
        }
        return report
    }
}
