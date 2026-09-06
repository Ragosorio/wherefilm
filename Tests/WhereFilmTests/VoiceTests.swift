import Testing
import Foundation
@testable import WhereFilmCore
@testable import WhereFilmIndex

@Suite("Voices")
struct VoiceTests {
    private func makeStore() throws -> IndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wherefilm-voices-\(UUID().uuidString).sqlite")
        return try IndexStore(url: url)
    }

    @discardableResult
    private func seedAsset(_ store: IndexStore, key: String, name: String) throws -> Int64 {
        try store.upsertVolume(Volume(volumeUUID: "vol-\(key)", name: "Test", fsType: "apfs",
                                      isOnline: true, lastSeenAt: Date()))
        var asset = Asset(contentKey: key, mediaType: .video, displayName: name,
                          indexedAt: Date())
        asset.durationSeconds = 600
        return try store.insert(asset).assetID!
    }

    private func vector(seed: Int, dimensions: Int = 32) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        values[seed % dimensions] = 1
        return VectorCodec.normalized(values)
    }

    private func segment(assetID: Int64, start: Double, end: Double, speaker: String,
                         seed: Int) -> VoiceSegment {
        let values = vector(seed: seed)
        let encoded = VectorCodec.encodeInt8(values)
        return VoiceSegment(assetID: assetID, startSeconds: start, endSeconds: end,
                            localSpeaker: speaker, modelID: "test-voice-v1",
                            dimensions: values.count, scale: encoded.scale,
                            vector: encoded.data, confidence: 0.9)
    }

    @Test("The same speaker in two different files becomes one voice")
    func clusteringCrossesFiles() async throws {
        // This is the entire point of clustering embeddings. A diarizer's
        // "Speaker 1" in one interview has no relationship to "Speaker 1" in the
        // next, so without this step a person who appears in forty files is
        // forty unrelated speakers.
        let store = try makeStore()
        let first = try seedAsset(store, key: "v1", name: "A.mov")
        let second = try seedAsset(store, key: "v2", name: "B.mov")

        let a = try store.replaceVoiceSegments(assetID: first, [
            segment(assetID: first, start: 0, end: 10, speaker: "S1", seed: 3)])
        let b = try store.replaceVoiceSegments(assetID: second, [
            segment(assetID: second, start: 0, end: 12, speaker: "S1", seed: 3)])

        let clusterer = VoiceClusterer()
        try await clusterer.assign(segments: a, store: store)
        try await clusterer.assign(segments: b, store: store)

        let voices = try store.voices()
        #expect(voices.count == 1)
        #expect(voices[0].segmentCount == 2)
    }

    @Test("Two different speakers stay apart")
    func differentSpeakersStayApart() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "v3", name: "C.mov")
        let stored = try store.replaceVoiceSegments(assetID: assetID, [
            segment(assetID: assetID, start: 0, end: 10, speaker: "S1", seed: 4),
            segment(assetID: assetID, start: 20, end: 30, speaker: "S2", seed: 19),
        ])
        try await VoiceClusterer().assign(segments: stored, store: store)
        #expect(try store.voices().count == 2)
    }

    @Test("A voice is only proposed for the face it actually shares time with")
    func proposalsFollowOverlap() async throws {
        // The bridge between the two halves: a voice and a face that keep
        // overlapping are very probably the same person. Proposing it is as far
        // as the machine goes — confirming an identity stays a person's job.
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "v4", name: "D.mov")
        let stored = try store.replaceVoiceSegments(assetID: assetID, [
            segment(assetID: assetID, start: 0, end: 60, speaker: "S1", seed: 5)])
        try await VoiceClusterer().assign(segments: stored, store: store)
        let voiceID = try #require(try store.voices().first?.voiceID)

        let speaker = try store.createPerson(centroid: vector(seed: 1), coverFaceID: nil)
        let bystander = try store.createPerson(centroid: vector(seed: 2), coverFaceID: nil)
        try store.replaceAppearances(assetID: assetID, [
            // On screen for almost all of the speech.
            PersonAppearance(personID: speaker.personID!, assetID: assetID,
                             startSeconds: 0, endSeconds: 55, confidence: 0.9),
            // Wanders through for four seconds.
            PersonAppearance(personID: bystander.personID!, assetID: assetID,
                             startSeconds: 10, endSeconds: 14, confidence: 0.9),
        ])

        let proposals = try await VoiceClusterer().proposals(store: store)
        #expect(proposals.count == 1, "one voice proposes one person, not everybody in the room")
        #expect(proposals.first?.voiceID == voiceID)
        #expect(proposals.first?.personID == speaker.personID)
        #expect((proposals.first?.coverage ?? 0) > 0.8)
    }

    @Test("Linking a voice makes the person findable where they speak, not only where they show")
    func linkedVoicesProduceAppearances() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "v5", name: "E.mov")
        let stored = try store.replaceVoiceSegments(assetID: assetID, [
            segment(assetID: assetID, start: 100, end: 130, speaker: "S1", seed: 7)])
        try await VoiceClusterer().assign(segments: stored, store: store)
        let voiceID = try #require(try store.voices().first?.voiceID)
        let person = try store.createPerson(centroid: vector(seed: 7), coverFaceID: nil)
        try store.link(voiceID: voiceID, to: person.personID)

        let refreshed = try store.voiceSegments(assetID: assetID)
        let intervals = SpokenAppearanceBuilder.intervals(
            from: refreshed, assetID: assetID, personOf: [voiceID: person.personID!])
        #expect(intervals.count == 1)
        #expect(intervals[0].source == "voice")
        #expect(intervals[0].startSeconds == 100)
        #expect(intervals[0].endSeconds == 130)
    }

    @Test("An unlinked voice is nobody, and produces no appearances")
    func unlinkedVoicesAreAnonymous() {
        let segments = [VoiceSegment(assetID: 1, startSeconds: 0, endSeconds: 10,
                                     localSpeaker: "S1", modelID: "t")]
        #expect(SpokenAppearanceBuilder.intervals(
            from: segments, assetID: 1, personOf: [:]).isEmpty)
    }

    @Test("Forgetting everyone forgets voices too")
    func erasureIncludesVoices() async throws {
        // Voice prints are biometric for exactly the same reasons faces are, so
        // the one button has to take both.
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "v6", name: "F.mov")
        try store.insertTranscript([TranscriptChunk(assetID: assetID, startSeconds: 0,
                                                    endSeconds: 5, text: "el presupuesto")])
        let stored = try store.replaceVoiceSegments(assetID: assetID, [
            segment(assetID: assetID, start: 0, end: 10, speaker: "S1", seed: 9)])
        try await VoiceClusterer().assign(segments: stored, store: store)
        #expect(try store.voiceStats().voices == 1)

        try store.forgetEveryone()

        let stats = try store.voiceStats()
        #expect(stats.segments == 0)
        #expect(stats.voices == 0)
        // And what was never about a person survives.
        #expect(try store.stats().assets == 1)
        #expect(try !store.textSearch(pattern: "\"presupuesto\"*", kinds: [.transcript]).isEmpty)
    }

    @Test("A Mac without a neural engine says so instead of failing obscurely")
    func unsupportedMachineIsExplicit() {
        // On Intel this whole feature is absent, and the product's shape is that
        // an absent capability is reported, never faked.
        let status = Diarizer.status
        #expect(!status.isEmpty)
        if !Diarizer.isSupported {
            #expect(status.contains("Apple silicon"))
        }
    }
}
