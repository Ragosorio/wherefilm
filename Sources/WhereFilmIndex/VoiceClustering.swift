import Foundation
import WhereFilmCore

/// Grouping voice segments into the people they belong to.
///
/// The diarizer answers "these three stretches are the same speaker" *within one
/// file*, and nothing more: its "Speaker 1" in one interview has no relationship
/// to "Speaker 1" in the next. Turning that into "this is the same person across
/// forty files" is the same problem faces have, so it is solved the same way and
/// with the same bias — too many clusters rather than too few, because merging
/// two people is a wrong answer somebody has to notice before they can fix it.
public actor VoiceClusterer {
    public struct Options: Sendable {
        /// Cosine similarity at which a segment joins an existing voice.
        ///
        /// Speaker embeddings separate better than the face descriptor currently
        /// shipped, so this can be stricter than its face counterpart. It is
        /// still a starting point to be measured per model rather than a belief.
        public var joinThreshold: Float = 0.7
        /// The bar for merging two whole voices, which moves many segments at
        /// once and so has to be more certain than a single join.
        public var mergeThreshold: Float = 0.78

        public init() {}
    }

    public var options: Options
    private var centroids: [(voiceID: Int64, vector: [Float])] = []
    private var loaded = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public func invalidate() { loaded = false }

    private func load(store: IndexStore) throws {
        guard !loaded else { return }
        centroids = try store.voices().compactMap { voice in
            guard let voiceID = voice.voiceID, let vector = voice.decodedCentroid,
                  !vector.isEmpty else { return nil }
            return (voiceID, vector)
        }
        loaded = true
    }

    @discardableResult
    public func assign(segments: [VoiceSegment], store: IndexStore) throws -> Int {
        guard !segments.isEmpty else { return 0 }
        try load(store: store)
        var created = 0

        for segment in segments {
            guard let segmentID = segment.segmentID, let vector = segment.decodedVector,
                  !vector.isEmpty else { continue }

            var best: (voiceID: Int64, similarity: Float)?
            for entry in centroids where entry.vector.count == vector.count {
                let similarity = VectorCodec.dot(entry.vector, vector)
                if similarity > (best?.similarity ?? -.greatestFiniteMagnitude) {
                    best = (entry.voiceID, similarity)
                }
            }

            if let best, best.similarity >= options.joinThreshold {
                try store.assign(segmentIDs: [segmentID], to: best.voiceID)
                refresh(voiceID: best.voiceID, store: store)
            } else {
                let voice = try store.createVoice(centroid: vector, modelID: segment.modelID)
                guard let voiceID = voice.voiceID else { continue }
                try store.assign(segmentIDs: [segmentID], to: voiceID)
                created += 1
                refresh(voiceID: voiceID, store: store)
            }
        }
        return created
    }

    private func refresh(voiceID: Int64, store: IndexStore) {
        guard let voice = try? store.voices().first(where: { $0.voiceID == voiceID }),
              let vector = voice.decodedCentroid, !vector.isEmpty else { return }
        if let index = centroids.firstIndex(where: { $0.voiceID == voiceID }) {
            centroids[index] = (voiceID, vector)
        } else {
            centroids.append((voiceID, vector))
        }
    }

    /// Proposes links between voices and the faces they keep overlapping with.
    ///
    /// This is the bridge between the two halves, and the reason both exist: a
    /// voice cluster and a face cluster that share time repeatedly are very
    /// likely the same person, and once linked, naming the face names the voice.
    /// After that "¿dónde habla Jorge?" works in the shots where he is off
    /// camera — which, in an interview, is most of them.
    ///
    /// Proposing is as far as this goes on its own. Confirming an identity is a
    /// person's job here, the same as naming a face.
    public struct Proposal: Sendable {
        public let voiceID: Int64
        public let personID: Int64
        public let sharedSeconds: Double
        /// Share of this voice's total speech that overlaps that person, 0…1.
        public let coverage: Double
    }

    public func proposals(store: IndexStore, minimumSeconds: Double = 10,
                          minimumCoverage: Double = 0.6) throws -> [Proposal] {
        let overlaps = try store.voicePersonOverlap(minimumSeconds: minimumSeconds)
        var totals: [Int64: Double] = [:]
        for voice in try store.voices() {
            guard let voiceID = voice.voiceID else { continue }
            let seconds = try store.voiceSegments(voiceID: voiceID)
                .reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }
            totals[voiceID] = seconds
        }

        // Best person per voice only. A voice that overlaps three faces is a
        // room with three people in it, not three identities for one speaker.
        var bestPerVoice: [Int64: Proposal] = [:]
        for overlap in overlaps {
            let total = totals[overlap.voiceID] ?? 0
            guard total > 0 else { continue }
            let coverage = min(1, overlap.seconds / total)
            guard coverage >= minimumCoverage else { continue }
            if coverage > (bestPerVoice[overlap.voiceID]?.coverage ?? 0) {
                bestPerVoice[overlap.voiceID] = Proposal(
                    voiceID: overlap.voiceID, personID: overlap.personID,
                    sharedSeconds: overlap.seconds, coverage: coverage)
            }
        }
        return bestPerVoice.values.sorted { $0.sharedSeconds > $1.sharedSeconds }
    }
}

/// Turning voice segments into the same kind of interval a face produces, so
/// "where does this person appear" and "where does this person speak" are the
/// same query against the same table.
public enum SpokenAppearanceBuilder {
    public static func intervals(from segments: [VoiceSegment], assetID: Int64,
                                 personOf: [Int64: Int64],
                                 gapSeconds: Double = 8) -> [PersonAppearance] {
        var byPerson: [Int64: [VoiceSegment]] = [:]
        for segment in segments {
            guard let voiceID = segment.voiceID, let personID = personOf[voiceID] else { continue }
            byPerson[personID, default: []].append(segment)
        }

        var out: [PersonAppearance] = []
        for (personID, rows) in byPerson {
            let sorted = rows.sorted { $0.startSeconds < $1.startSeconds }
            var start = sorted[0].startSeconds
            var end = sorted[0].endSeconds
            var confidences: [Double] = [sorted[0].confidence ?? 0.6]

            func close() {
                out.append(PersonAppearance(
                    personID: personID, assetID: assetID,
                    startSeconds: start, endSeconds: max(end, start + 0.5),
                    confidence: confidences.reduce(0, +) / Double(confidences.count),
                    source: "voice"))
            }

            for segment in sorted.dropFirst() {
                if segment.startSeconds - end > gapSeconds {
                    close()
                    start = segment.startSeconds
                    confidences = []
                }
                end = max(end, segment.endSeconds)
                confidences.append(segment.confidence ?? 0.6)
            }
            close()
        }
        return out.sorted { $0.startSeconds < $1.startSeconds }
    }
}
