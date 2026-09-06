import Foundation
import WhereFilmCore

/// Deciding which faces are the same person, without being told first.
///
/// Two passes, for the same reason the rest of the indexer has two: the cheap one
/// runs while indexing and is allowed to be wrong in one direction, and the
/// careful one runs later and fixes it.
///
/// **Online** — every new face is compared against the clusters that exist. Close
/// enough joins; otherwise it starts its own. This is deliberately biased towards
/// *too many* clusters: splitting a person across three groups is a nuisance,
/// while merging two people into one is a wrong answer that a person has to
/// notice before they can fix it.
///
/// **Offline** — a later pass looks at the clusters themselves and merges the
/// ones the online pass could not know were the same, because the face that would
/// have connected them had not been seen yet.
public actor FaceClusterer {
    public struct Options: Sendable {
        /// Cosine similarity at which a face joins an existing cluster.
        ///
        /// Measured for AuraFace over 24 photographs of four public figures
        /// across many years and photographers — the hard case, and the one an
        /// archive actually contains. With eye-aligned crops:
        ///
        ///     same person       p50 0.397
        ///     different people  p50 0.254   p95 0.423
        ///
        /// 0.45 sits above the 95th percentile of *different* people, which is
        /// the number that matters. It splits one person across a few clusters,
        /// and it does not put two people in one.
        ///
        /// The right value depends entirely on which model produced the vectors,
        /// so this is a measurement and not a belief — `Scripts/fetch-face-fixture.sh`
        /// builds the fixture that produced it.
        public var joinThreshold: Float = 0.45
        /// The bar for merging two whole clusters, which affects many faces at
        /// once and so has to be at least as certain as a single join.
        ///
        /// Measured on the same fixture, consolidating 17 clusters over 26 faces
        /// of four people:
        ///
        ///     0.55   merged 0    17 clusters   purity 96%
        ///     0.50   merged 1    16 clusters   purity 96%
        ///     0.40   merged 8     9 clusters   purity 69%   ← one cluster ate two people
        ///
        /// The cliff between 0.45 and 0.40 is the whole argument for the bias
        /// this file is written around. Fewer clusters look tidier right up to
        /// the moment two people become one, and that is the error nobody
        /// notices in an archive of thousands of faces.
        public var mergeThreshold: Float = 0.50
        /// A cluster this small is probably a bad crop rather than a person.
        public var minimumClusterSize = 2

        public init() {}
    }

    public var options: Options
    private var centroids: [(personID: Int64, vector: [Float], isNamed: Bool)] = []
    private var loaded = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public func invalidate() { loaded = false }

    private func load(store: IndexStore) throws {
        guard !loaded else { return }
        centroids = try store.people().compactMap { person in
            guard let personID = person.personID, let vector = person.decodedCentroid,
                  !vector.isEmpty else { return nil }
            return (personID, vector, person.isNamed)
        }
        loaded = true
    }

    /// Files freshly stored faces into clusters, creating clusters as needed.
    @discardableResult
    public func assign(faces: [FaceRow], store: IndexStore) throws -> Int {
        guard !faces.isEmpty else { return 0 }
        try load(store: store)
        var created = 0

        for face in faces {
            guard let faceID = face.faceID else { continue }
            let vector = face.decodedVector
            guard !vector.isEmpty else { continue }

            var best: (personID: Int64, similarity: Float)?
            for entry in centroids where entry.vector.count == vector.count {
                let similarity = VectorCodec.dot(entry.vector, vector)
                if similarity > (best?.similarity ?? -.greatestFiniteMagnitude) {
                    best = (entry.personID, similarity)
                }
            }

            if let best, best.similarity >= options.joinThreshold {
                try store.assign(faceIDs: [faceID], to: best.personID)
                refresh(personID: best.personID, store: store)
            } else {
                let person = try store.createPerson(centroid: vector, coverFaceID: faceID)
                guard let personID = person.personID else { continue }
                try store.assign(faceIDs: [faceID], to: personID)
                created += 1
                refresh(personID: personID, store: store)
            }
        }
        return created
    }

    private func refresh(personID: Int64, store: IndexStore) {
        guard let person = try? store.person(id: personID),
              let vector = person.decodedCentroid, !vector.isEmpty else { return }
        if let index = centroids.firstIndex(where: { $0.personID == personID }) {
            centroids[index] = (personID, vector, person.isNamed)
        } else {
            centroids.append((personID, vector, person.isNamed))
        }
    }

    /// The consolidation pass: merges clusters that turned out to be the same
    /// person, and refuses to merge the ones a person has already ruled on.
    ///
    /// Two rules make this safe to run unattended:
    ///
    ///  - **Two named clusters are never merged.** If somebody has said one is
    ///    Jorge and the other is Marta, a cosine number does not get to disagree.
    ///  - **A split is permanent.** "These twelve are not him" is recorded in
    ///    `people_feedback`, and no later pass may put them back.
    @discardableResult
    public func consolidate(store: IndexStore) throws -> Int {
        invalidate()
        try load(store: store)
        let forbidden = try store.splitPairs()
        var merged = 0

        var active = centroids
        var index = 0
        while index < active.count {
            var target = active[index]
            var other = index + 1
            while other < active.count {
                let candidate = active[other]
                let bothNamed = target.isNamed && candidate.isNamed
                let wasSplit = forbidden.contains(IndexStore.Pair(target.personID, candidate.personID))
                let similar = target.vector.count == candidate.vector.count
                    && VectorCodec.dot(target.vector, candidate.vector) >= options.mergeThreshold
                guard similar, !bothNamed, !wasSplit else {
                    other += 1
                    continue
                }
                // The named cluster survives, so a merge never loses a name.
                let (keep, drop) = target.isNamed || !candidate.isNamed
                    ? (target.personID, candidate.personID)
                    : (candidate.personID, target.personID)
                try store.merge(personID: drop, into: keep)
                merged += 1
                if let refreshed = try store.person(id: keep),
                   let vector = refreshed.decodedCentroid {
                    target = (keep, vector, refreshed.isNamed)
                    active[index] = target
                }
                active.remove(at: other)
            }
            index += 1
        }
        centroids = active
        _ = try store.pruneEmptyPeople()
        return merged
    }
}

/// Turning individual detections into "Jorge appears from 14:12 to 14:31".
public enum AppearanceBuilder {
    /// How long a person may be missing from the sampled frames before it counts
    /// as a different appearance.
    ///
    /// Keyframes are sampled every few seconds and a person who turns their head
    /// vanishes from one of them. Closing the interval on every gap would produce
    /// a list of forty one-second appearances for a single continuous shot, which
    /// is a worse answer than one that says 14:12–14:31.
    public static let defaultGapSeconds: Double = 12

    public static func intervals(from faces: [FaceRow], assetID: Int64,
                                 gapSeconds: Double = defaultGapSeconds,
                                 minimumSeconds: Double = 0.5) -> [PersonAppearance] {
        var byPerson: [Int64: [FaceRow]] = [:]
        for face in faces {
            guard let personID = face.personID else { continue }
            byPerson[personID, default: []].append(face)
        }

        var out: [PersonAppearance] = []
        for (personID, rows) in byPerson {
            let sorted = rows.sorted { $0.seconds < $1.seconds }
            var start = sorted[0].seconds
            var end = sorted[0].seconds
            var confidences: [Double] = [sorted[0].quality ?? 0.5]

            func close() {
                let span = max(end - start, minimumSeconds)
                out.append(PersonAppearance(
                    personID: personID, assetID: assetID,
                    startSeconds: start, endSeconds: start + span,
                    confidence: confidences.reduce(0, +) / Double(confidences.count),
                    source: "face"))
            }

            for face in sorted.dropFirst() {
                if face.seconds - end > gapSeconds {
                    close()
                    start = face.seconds
                    confidences = []
                }
                end = face.seconds
                confidences.append(face.quality ?? 0.5)
            }
            close()
        }
        return out.sorted { $0.startSeconds < $1.startSeconds }
    }
}
