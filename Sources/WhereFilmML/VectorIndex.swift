import Foundation
import USearch
import WhereFilmCore

/// The approximate-nearest-neighbour index over moment embeddings.
///
/// Deliberately *derived* state. SQLite holds the vectors; this holds an HNSW
/// graph built from them. If it is corrupted, or the visual model changes, it can
/// be deleted and rebuilt — nothing is lost. That is why the product does not
/// need a vector *server*: a `.sqlite` and a `.usearch` next to each other are
/// the whole storage story.
public actor VectorIndex {
    public let modelID: String
    public let dimensions: Int
    private let url: URL
    private var index: USearchIndex
    private var isReadOnlyView = false
    /// USearch's Swift wrapper keeps `length`/`capacity` internal, so the actor
    /// tracks them itself.
    private var storedCount = 0
    private var reservedCapacity = 0

    public init(modelID: String, dimensions: Int, directory: URL = AppPaths.vectorIndexes) throws {
        self.modelID = modelID
        self.dimensions = dimensions
        self.url = directory.appendingPathComponent("\(modelID).usearch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.index = try Self.makeIndex(dimensions: dimensions)
    }

    private static func makeIndex(dimensions: Int) throws -> USearchIndex {
        // Vectors are stored unit length, so cosine and dot product agree.
        // f16 internally: half the memory of f32 with no measurable recall cost
        // at these dimensions.
        try USearchIndex.make(metric: .cos, dimensions: UInt32(dimensions),
                              connectivity: 16, quantization: .f16)
    }

    public var count: Int { storedCount }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Persistence

    /// Memory-maps the index from disk instead of loading it into RAM.
    ///
    /// This is what lets a menu-bar app hold millions of moments ready to search
    /// while occupying tens of megabytes.
    public func openForSearch() throws {
        guard fileExists else { return }
        index = try Self.makeIndex(dimensions: dimensions)
        try index.view(path: url.path)
        isReadOnlyView = true
        storedCount = readMeta()
        reservedCapacity = storedCount
    }

    /// Loads the index into memory so it can be modified.
    public func openForWriting() throws {
        index = try Self.makeIndex(dimensions: dimensions)
        storedCount = 0
        reservedCapacity = 0
        if fileExists {
            try index.load(path: url.path)
            storedCount = readMeta()
            reservedCapacity = storedCount
        }
        isReadOnlyView = false
    }

    public func save() throws {
        guard !isReadOnlyView else { return }
        try index.save(path: url.path)
        writeMeta()
    }

    public func deleteFile() throws {
        if fileExists { try FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: metaURL)
        index = try Self.makeIndex(dimensions: dimensions)
        isReadOnlyView = false
        storedCount = 0
        reservedCapacity = 0
    }

    // MARK: - Mutation

    public func add(momentID: Int64, vector: [Float]) throws {
        try ensureCapacity(extra: 1)
        try index.add(key: USearchKey(momentID), vector: vector)
        storedCount += 1
    }

    public func add(_ pairs: [(momentID: Int64, vector: [Float])]) throws {
        guard !pairs.isEmpty else { return }
        try ensureCapacity(extra: pairs.count)
        for (momentID, vector) in pairs {
            // A re-index of the same moment replaces the old vector rather than
            // producing a phantom duplicate hit.
            if try index.contains(key: USearchKey(momentID)) {
                storedCount -= Int(try index.remove(key: USearchKey(momentID)))
            }
            try index.add(key: USearchKey(momentID), vector: vector)
            storedCount += 1
        }
    }

    public func remove(momentID: Int64) throws {
        storedCount -= Int(try index.remove(key: USearchKey(momentID)))
    }

    private func ensureCapacity(extra: Int) throws {
        let needed = storedCount + extra
        if needed > reservedCapacity {
            // Grow generously: reserving is not free, and indexing arrives in bursts.
            reservedCapacity = max(needed * 2, 1024)
            try index.reserve(UInt32(reservedCapacity))
        }
    }

    /// USearch's Swift wrapper hides the graph size, so the count is persisted
    /// next to the index. It is a hint, not truth — SQLite remains authoritative,
    /// and a wrong hint costs at most one unnecessary `reserve`.
    private var metaURL: URL { url.appendingPathExtension("meta") }

    private func readMeta() -> Int {
        guard let data = try? Data(contentsOf: metaURL),
              let text = String(data: data, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return value
    }

    private func writeMeta() {
        try? Data("\(storedCount)".utf8).write(to: metaURL, options: .atomic)
    }

    // MARK: - Search

    public struct Hit: Sendable {
        public let momentID: Int64
        /// Cosine similarity in [-1, 1]; higher is better.
        public let similarity: Float
    }

    public func search(_ vector: [Float], limit: Int) throws -> [Hit] {
        guard storedCount > 0 else { return [] }
        let (keys, distances) = try index.search(vector: vector, count: limit)
        return zip(keys, distances).map { key, distance in
            // USearch reports cosine *distance*; the product speaks similarity.
            Hit(momentID: Int64(bitPattern: key), similarity: 1 - distance)
        }
    }

    // MARK: - Rebuild

    /// Rebuilds the whole graph from SQLite. Runs at `.background` QoS and is
    /// always safe to interrupt — a partial rebuild just gets redone.
    public func rebuild(from store: IndexStore,
                        progress: (@Sendable (Int) -> Void)? = nil) throws {
        try deleteFile()
        try openForWriting()
        var total = 0
        try store.forEachEmbedding(modelID: modelID) { batch in
            try self.addSynchronously(batch.map { ($0.momentID, $0.vector) })
            total += batch.count
            progress?(total)
        }
        try save()
    }

    private func addSynchronously(_ pairs: [(momentID: Int64, vector: [Float])]) throws {
        try add(pairs)
    }
}

/// Exhaustive scan over the vectors in SQLite.
///
/// Slower than HNSW at millions of moments, but exact — which makes it both a
/// perfectly good path for small libraries and the yardstick for checking that
/// the ANN index is returning what it should.
public enum LinearVectorSearch {
    public static func search(store: IndexStore, modelID: String,
                              query: [Float], limit: Int) throws -> [VectorIndex.Hit] {
        var best: [VectorIndex.Hit] = []
        try store.forEachEmbedding(modelID: modelID) { batch in
            for embedding in batch {
                let similarity = VectorCodec.dot(query, embedding.vector)
                if best.count < limit {
                    best.append(.init(momentID: embedding.momentID, similarity: similarity))
                    best.sort { $0.similarity > $1.similarity }
                } else if similarity > best[best.count - 1].similarity {
                    best[best.count - 1] = .init(momentID: embedding.momentID, similarity: similarity)
                    best.sort { $0.similarity > $1.similarity }
                }
            }
        }
        return best
    }
}

/// Version and SIMD details of the bundled vector engine, surfaced by
/// `wherefilm doctor` so performance questions can be answered with facts
/// instead of assumptions.
public enum VectorEngineInfo {
    public static var version: String { usearchVersion() }
    public static var acceleration: String { usearchHardwareAccelerationAvailable() }
}
