import Testing
import Foundation
import CoreGraphics
@testable import WhereFilmCore
@testable import WhereFilmIndex

@Suite("People")
struct PeopleTests {
    private func makeStore() throws -> IndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wherefilm-people-\(UUID().uuidString).sqlite")
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

    /// A vector that points mostly in one direction, so "the same person" and
    /// "somebody else" are controllable rather than hoped for.
    private func vector(seed: Int, dimensions: Int = 64, noise: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        values[seed % dimensions] = 1
        if noise > 0 {
            for index in values.indices { values[index] += noise * Float((index * seed) % 7) / 7 }
        }
        return VectorCodec.normalized(values)
    }

    private func face(_ store: IndexStore, assetID: Int64, momentID: Int64, seconds: Double,
                      seed: Int, noise: Float = 0, quality: Double = 0.8) throws -> FaceRow {
        let values = vector(seed: seed, noise: noise)
        let encoded = VectorCodec.encodeInt8(values)
        let row = FaceRow(momentID: momentID, assetID: assetID, seconds: seconds,
                          x: 0.4, y: 0.4, width: 0.2, height: 0.2, quality: quality,
                          modelID: "test-face-v1", dimensions: values.count,
                          scale: encoded.scale, vector: encoded.data)
        return try store.insertFaces([row])[0]
    }

    // MARK: - Cropping and gating

    @Test("A face too small, too blurry or too turned away is not embedded")
    func qualityGateRejectsHopelessFaces() {
        // Most faces in real footage are one of these three, and embedding them
        // is not merely wasted: they land between clusters and are how one
        // person ends up scattered across a dozen of them.
        let good = DetectedFace(x: 0.4, y: 0.4, width: 0.2, height: 0.25,
                                quality: 0.8, yaw: 5)
        let tiny = DetectedFace(x: 0.4, y: 0.4, width: 0.01, height: 0.01, quality: 0.9)
        let blurry = DetectedFace(x: 0.4, y: 0.4, width: 0.2, height: 0.25, quality: 0.1)
        let turned = DetectedFace(x: 0.4, y: 0.4, width: 0.2, height: 0.25,
                                  quality: 0.8, yaw: 70)

        #expect(FaceCrop.isWorthEmbedding(good, frameWidth: 1024))
        #expect(!FaceCrop.isWorthEmbedding(tiny, frameWidth: 1024))
        #expect(!FaceCrop.isWorthEmbedding(blurry, frameWidth: 1024))
        #expect(!FaceCrop.isWorthEmbedding(turned, frameWidth: 1024))
    }

    @Test("The crop takes the face, not the ceiling above it")
    func cropFlipsVisionCoordinatesCorrectly() throws {
        // Vision normalises with the origin at the lower left; CGImage crops from
        // the upper left. Getting that flip wrong produces crops of foreheads and
        // ceilings — a bug that looks exactly like a bad model.
        let width = 400, height = 400
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // White everywhere, black square in the BOTTOM-left quarter as CGImage
        // sees it — which Vision would call the TOP-left.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try #require(context.makeImage())

        // A "face" in Vision's coordinates at the TOP-left — y measured up from
        // the bottom, so 0.5…1.0 is the upper half. That is the white half.
        let upper = DetectedFace(x: 0.05, y: 0.55, width: 0.3, height: 0.35, quality: 0.9)
        let cropped = try #require(FaceCrop.cut(upper, from: image))
        #expect(cropped.width == FaceCrop.side)
        #expect(Self.averageBrightness(of: cropped) > 0.7,
                "Vision's top-left is the white half; a crop that is dark took the wrong one")

        let lower = DetectedFace(x: 0.05, y: 0.05, width: 0.3, height: 0.35, quality: 0.9)
        let darkCrop = try #require(FaceCrop.cut(lower, from: image))
        #expect(Self.averageBrightness(of: darkCrop) < 0.4)
    }

    static func averageBrightness(of image: CGImage) -> Double {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
    }

    // MARK: - Clustering

    @Test("Faces that look alike land in one group; strangers do not")
    func clusteringSeparatesPeople() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "c1", name: "A.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)

        let clusterer = FaceClusterer()
        var faces: [FaceRow] = []
        for index in 0..<3 {
            faces.append(try face(store, assetID: assetID, momentID: moment,
                                  seconds: Double(index), seed: 1))
        }
        faces.append(try face(store, assetID: assetID, momentID: moment, seconds: 9, seed: 40))
        try await clusterer.assign(faces: faces, store: store)

        let people = try store.people()
        #expect(people.count == 2, "three of one person and one of another are two groups")
        #expect(people.contains { $0.faceCount == 3 })
        #expect(people.contains { $0.faceCount == 1 })
    }

    @Test("A name makes a person findable, misspelled and unaccented")
    func namesAreFoundTolerantly() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "n1", name: "B.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)
        let stored = try face(store, assetID: assetID, momentID: moment, seconds: 1, seed: 2)
        try await FaceClusterer().assign(faces: [stored], store: store)
        let personID = try #require(try store.people().first?.personID)

        try store.name(personID: personID, as: "Jorge Álvarez")

        // The exact name, the unaccented spelling, and the misspelling somebody
        // actually types. A prefix index finds none of the last two.
        #expect(try !store.people(namedLike: "Jorge Álvarez").isEmpty)
        #expect(try !store.people(namedLike: "Jorge Alvarez").isEmpty)
        #expect(try !store.people(namedLike: "Alvares").isEmpty)
        #expect(try store.people(namedLike: "Marta Gonzalez").isEmpty)
    }

    @Test("Consolidation never merges two named people, nor undoes a split")
    func consolidationRespectsCorrections() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "m1", name: "C.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)

        // Two groups of the *same* vector: consolidation would merge them.
        let first = try face(store, assetID: assetID, momentID: moment, seconds: 1, seed: 3)
        let second = try face(store, assetID: assetID, momentID: moment, seconds: 2, seed: 3)
        let a = try store.createPerson(centroid: first.decodedVector, coverFaceID: first.faceID)
        let b = try store.createPerson(centroid: second.decodedVector, coverFaceID: second.faceID)
        try store.assign(faceIDs: [first.faceID!], to: a.personID!)
        try store.assign(faceIDs: [second.faceID!], to: b.personID!)

        try store.name(personID: a.personID!, as: "Jorge")
        try store.name(personID: b.personID!, as: "Marta")

        let merged = try await FaceClusterer().consolidate(store: store)
        #expect(merged == 0, "a cosine number does not get to overrule two names")
        #expect(try store.people().count == 2)
    }

    @Test("A split is permanent")
    func splitsSurviveConsolidation() async throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "s1", name: "D.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)

        var faces: [FaceRow] = []
        for index in 0..<4 {
            faces.append(try face(store, assetID: assetID, momentID: moment,
                                  seconds: Double(index), seed: 5))
        }
        try await FaceClusterer().assign(faces: faces, store: store)
        let personID = try #require(try store.people().first?.personID)

        let wrong = Array(faces.suffix(2).compactMap(\.faceID))
        let newID = try #require(try store.split(faceIDs: wrong, from: personID))
        #expect(try store.people().count == 2)

        // Identical vectors, so consolidation would certainly merge them back if
        // it were allowed to. "These two are not the same person" has to outlive
        // every later pass or the correction is theatre.
        let merged = try await FaceClusterer().consolidate(store: store)
        #expect(merged == 0)
        #expect(try store.person(id: newID) != nil)
    }

    @Test("An automatic pass may not move a face a person placed")
    func userAssignmentsAreSticky() throws {
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "u1", name: "E.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)
        let stored = try face(store, assetID: assetID, momentID: moment, seconds: 1, seed: 7)
        let mine = try store.createPerson(centroid: stored.decodedVector, coverFaceID: nil)
        let theirs = try store.createPerson(centroid: stored.decodedVector, coverFaceID: nil)

        try store.assign(faceIDs: [stored.faceID!], to: mine.personID!, assignedBy: "user")
        try store.assign(faceIDs: [stored.faceID!], to: theirs.personID!, assignedBy: "auto")

        let after = try #require(try store.face(id: stored.faceID!))
        #expect(after.personID == mine.personID, "the automatic pass must not overrule a person")
        #expect(after.isPlacedByUser)
    }

    // MARK: - Appearances

    @Test("Appearances are intervals, and a short gap does not end one")
    func appearancesMergeAcrossSampling() {
        // Keyframes are sampled every few seconds and a person who turns their
        // head vanishes from one of them. Closing on every gap would answer
        // "¿en qué minuto sale Jorge?" with forty one-second appearances.
        let rows = [0.0, 5.0, 10.0, 15.0, 120.0, 125.0].map { seconds in
            FaceRow(momentID: 1, assetID: 1, seconds: seconds, x: 0, y: 0, width: 0.2,
                    height: 0.2, quality: 0.9, modelID: "t", dimensions: 4,
                    vector: Data([1, 2, 3, 4]), personID: 7)
        }
        let intervals = AppearanceBuilder.intervals(from: rows, assetID: 1)
        #expect(intervals.count == 2, "one continuous stretch, then a separate one later")
        #expect(intervals[0].startSeconds == 0)
        #expect(intervals[0].endSeconds >= 15)
        #expect(intervals[1].startSeconds == 120)
    }

    @Test("Faces with no person yet produce no appearances")
    func unassignedFacesAreNotAppearances() {
        let rows = [FaceRow(momentID: 1, assetID: 1, seconds: 3, x: 0, y: 0, width: 0.2,
                            height: 0.2, modelID: "t", dimensions: 4,
                            vector: Data([1, 2, 3, 4]))]
        #expect(AppearanceBuilder.intervals(from: rows, assetID: 1).isEmpty)
    }

    // MARK: - Erasure

    @Test("Forgetting everyone leaves a working library that never met anyone")
    func erasureIsNarrow() async throws {
        // Biometric data that cannot be removed on demand should not be
        // collected, so this has to be provably narrow rather than promised.
        let store = try makeStore()
        let assetID = try seedAsset(store, key: "e1", name: "F.mov")
        let moment = try #require(try store.insertMoments([
            Moment(assetID: assetID, startSeconds: 0, endSeconds: 5)]).first?.momentID)
        try store.insertOCR([OCRText(momentID: moment, assetID: assetID, text: "CLAQUETA 3")],
                            momentTimes: [moment: (0, 5)])
        try store.insertTranscript([TranscriptChunk(assetID: assetID, startSeconds: 0,
                                                    endSeconds: 5, text: "el presupuesto")])
        let stored = try face(store, assetID: assetID, momentID: moment, seconds: 1, seed: 11)
        try await FaceClusterer().assign(faces: [stored], store: store)
        let personID = try #require(try store.people().first?.personID)
        try store.name(personID: personID, as: "Jorge Álvarez")
        try store.replaceAppearances(assetID: assetID, [
            PersonAppearance(personID: personID, assetID: assetID, startSeconds: 0,
                             endSeconds: 5, confidence: 0.9)])

        try store.forgetEveryone()

        let stats = try store.peopleStats()
        #expect(stats.faces == 0)
        #expect(stats.people == 0)
        #expect(stats.appearances == 0)
        #expect(try store.people(namedLike: "Jorge Álvarez").isEmpty)

        // And everything that was never about a person is still there.
        #expect(try store.stats().assets == 1)
        #expect(try store.moments(assetID: assetID).count == 1)
        #expect(try !store.textSearch(pattern: "\"claqueta\"*", kinds: [.ocr]).isEmpty)
        #expect(try !store.textSearch(pattern: "\"presupuesto\"*", kinds: [.transcript]).isEmpty)
    }
}
