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
    private enum OpenMode { case fresh, readOnly, writable }
    private var openMode: OpenMode = .fresh
    /// Capacity is not readable from the wrapper, so growth is tracked here.
    /// The *count* deliberately is not — see `count`.
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

    /// How many vectors the graph holds, asked of the graph itself.
    ///
    /// This used to be a number cached in a `.usearch.meta` sidecar, written
    /// with `try?`. That failed for real: a disk that filled up during a rebuild
    /// left a perfectly valid 238 MB graph on disk next to a missing sidecar, so
    /// the count read back as zero, the ANN index was silently treated as empty,
    /// and every search fell back to an exhaustive scan of 208,801 vectors —
    /// 9.1 s instead of milliseconds, with nothing anywhere saying why.
    ///
    /// The pinned USearch wrapper exposes the real length. Deriving the number
    /// from the graph makes that entire failure mode impossible rather than
    /// merely unlikely.
    public var count: Int { (try? index.count) ?? 0 }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Persistence

    /// Memory-maps the index from disk instead of loading it into RAM.
    ///
    /// This is what lets a menu-bar app hold millions of moments ready to search
    /// while occupying tens of megabytes.
    public func openForSearch() throws {
        // The app intentionally shares one actor between indexing and search.
        // Replacing a live writable graph with a read-only mmap here made the
        // next background add fail exactly when somebody searched mid-index.
        // A writable graph is already searchable; never downgrade it.
        guard openMode != .writable else { return }
        guard openMode != .readOnly else { return }
        guard fileExists else { return }
        index = try Self.makeIndex(dimensions: dimensions)
        try index.view(path: url.path)
        openMode = .readOnly
        reservedCapacity = count
    }

    /// Loads the index into memory so it can be modified.
    public func openForWriting() throws {
        // Re-entering this method must not throw away unsaved vectors already in
        // memory. `drain` and the long-running loop both defensively call it.
        guard openMode != .writable else { return }
        index = try Self.makeIndex(dimensions: dimensions)
        reservedCapacity = 0
        if fileExists {
            try index.load(path: url.path)
            reservedCapacity = count
        }
        openMode = .writable
    }

    public func save() throws {
        guard openMode == .writable else { return }
        try index.save(path: url.path)
    }

    public func deleteFile() throws {
        if fileExists { try FileManager.default.removeItem(at: url) }
        // Left behind by older versions, which cached the vector count beside
        // the graph. Nothing reads it any more; clean it up on the way past.
        try? FileManager.default.removeItem(at: legacyMetaURL)
        index = try Self.makeIndex(dimensions: dimensions)
        openMode = .writable
        reservedCapacity = 0
    }

    // MARK: - Mutation

    public func add(momentID: Int64, vector: [Float]) throws {
        try ensureCapacity(extra: 1)
        try index.add(key: USearchKey(momentID), vector: vector)
    }

    public func add(_ pairs: [(momentID: Int64, vector: [Float])]) throws {
        guard !pairs.isEmpty else { return }
        try ensureCapacity(extra: pairs.count)
        for (momentID, vector) in pairs {
            // A re-index of the same moment replaces the old vector rather than
            // producing a phantom duplicate hit.
            if try index.contains(key: USearchKey(momentID)) {
                _ = try index.remove(key: USearchKey(momentID))
            }
            try index.add(key: USearchKey(momentID), vector: vector)
        }
    }

    public func remove(momentID: Int64) throws {
        _ = try index.remove(key: USearchKey(momentID))
    }

    private func ensureCapacity(extra: Int) throws {
        let needed = count + extra
        if needed > reservedCapacity {
            // Grow generously: reserving is not free, and indexing arrives in bursts.
            reservedCapacity = max(needed * 2, 1024)
            try index.reserve(UInt32(reservedCapacity))
        }
    }

    /// Written by versions that cached the count on disk. Only ever deleted now.
    private var legacyMetaURL: URL { url.appendingPathExtension("meta") }

    // MARK: - Search

    public struct Hit: Sendable {
        public let momentID: Int64
        /// Cosine similarity in [-1, 1]; higher is better.
        public let similarity: Float
    }

    public func search(_ vector: [Float], limit: Int) throws -> [Hit] {
        guard count > 0 else { return [] }
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
        guard limit > 0 else { return [] }
        // Keep the running top-K sorted by *insertion*, not by re-sorting.
        //
        // The previous version called `sort` on the whole top-K every time a
        // candidate beat the worst one, which is O(k log k) work to move a
        // single element. With the default depth of 300 that is roughly 2,500
        // comparisons per improvement, repeated across every vector in the
        // library. Almost all candidates lose to the worst survivor and are
        // rejected by the first comparison; the rest need one binary search and
        // one shift.
        var best: [VectorIndex.Hit] = []
        best.reserveCapacity(limit)
        var worst = -Float.greatestFiniteMagnitude

        try store.forEachEmbedding(modelID: modelID) { batch in
            for embedding in batch {
                let similarity = VectorCodec.dot(query, embedding.vector)
                if best.count == limit && similarity <= worst { continue }

                var low = 0
                var high = best.count
                while low < high {
                    let mid = (low + high) / 2
                    if best[mid].similarity >= similarity { low = mid + 1 } else { high = mid }
                }
                best.insert(.init(momentID: embedding.momentID, similarity: similarity), at: low)
                if best.count > limit { best.removeLast() }
                if best.count == limit { worst = best[best.count - 1].similarity }
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
