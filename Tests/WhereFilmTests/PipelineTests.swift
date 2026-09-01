import Testing
import Foundation
import CoreGraphics
@testable import WhereFilmCore
@testable import WhereFilmML
@testable import WhereFilmIndex

@Suite("Keyframe selection")
struct KeyframeTests {
    private func solidImage(_ gray: UInt8) -> CGImage {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: gray, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }

    private func gradientImage(flipped: Bool) -> CGImage {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(truncatingIfNeeded: flipped ? width - x : x)
                pixels[y * width + x] = value
            }
        }
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }

    @Test("Identical frames hash identically")
    func identicalFrames() {
        let a = KeyframeSampler.differenceHash(solidImage(128))
        let b = KeyframeSampler.differenceHash(solidImage(128))
        #expect(a == b)
        #expect(KeyframeSampler.hammingDistance(a, b) == 0)
    }

    @Test("A reversed gradient is a completely different frame")
    func opposedGradients() {
        let left = KeyframeSampler.differenceHash(gradientImage(flipped: false))
        let right = KeyframeSampler.differenceHash(gradientImage(flipped: true))
        // Every horizontal comparison flips, so the two hashes should be
        // near-complements — comfortably above the shot-change threshold.
        #expect(KeyframeSampler.hammingDistance(left, right) > 32)
    }

    @Test("A static interview yields a moment per kept frame, closed at the next one")
    func momentsCloseAtTheNextKeyframe() {
        let moments = KeyframeSampler.moments(
            assetID: 1,
            frames: [(0, 1), (30.5, 2), (95, 3)],
            durationSeconds: 120)

        #expect(moments.count == 3)
        #expect(moments[0].startSeconds == 0)
        #expect(moments[0].endSeconds == 30.5)     // ends where the next shot starts
        #expect(moments[1].endSeconds == 95)
        #expect(moments[2].endSeconds == 120)      // last one runs to the end
    }

    @Test("An empty frame list produces no moments")
    func noFramesNoMoments() {
        #expect(KeyframeSampler.moments(assetID: 1, frames: [], durationSeconds: 60).isEmpty)
    }
}

@Suite("Resource governor")
struct GovernorTests {
    @Test("Paused means paused")
    func pausedStopsEverything() {
        var settings = ResourceGovernor.Settings()
        settings.mode = .paused
        let decision = ResourceGovernor(settings: settings).decide()
        #expect(!decision.isWorking)
        #expect(decision.reason == .userPaused)
        #expect(decision.allowedTasks.isEmpty)
    }

    @Test("Pause for two hours expires on its own")
    func timedPauseExpires() {
        var settings = ResourceGovernor.Settings()
        settings.mode = .smart
        settings.pausedUntil = Date().addingTimeInterval(7200)
        let governor = ResourceGovernor(settings: settings)

        #expect(!governor.decide().isWorking)
        // Two hours and one second later the indexer picks itself back up.
        #expect(governor.decide(now: Date().addingTimeInterval(7201)).reason != .userPaused)
    }

    @Test("Full speed still respects a critical thermal state")
    func fullSpeedIsNotReckless() {
        var settings = ResourceGovernor.Settings()
        settings.mode = .fullSpeed
        let decision = ResourceGovernor(settings: settings).decide()
        // On a healthy machine this runs everything; the point of the assertion
        // is that the decision is coherent either way.
        if ProcessInfo.processInfo.thermalState == .critical {
            #expect(!decision.isWorking)
        } else {
            #expect(decision.allowedTasks.count == JobTask.allCases.count)
        }
    }

    @Test("Editing apps are recognised by bundle id")
    func editorsAreKnown() {
        let settings = ResourceGovernor.Settings()
        #expect(settings.editorBundleIDs.contains("com.blackmagic-design.DaVinciResolve"))
        #expect(settings.editorBundleIDs.contains("com.adobe.PremierePro"))
        #expect(settings.editorBundleIDs.contains("com.apple.FinalCut"))
    }
}

@Suite("Media type detection")
struct MediaProbeTests {
    @Test("Common camera formats are recognised")
    func extensions() {
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/B.MOV")) == .video)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.mxf")) == .video)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.braw")) == .video)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.HEIC")) == .image)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.cr3")) == .image)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.wav")) == .audio)
        #expect(MediaProbe.mediaType(for: URL(fileURLWithPath: "/a/b.pdf")) == nil)
    }
}

@Suite("Vector index")
struct VectorIndexTests {
    @Test("An index survives a round trip through disk, memory-mapped")
    func saveAndView() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-vec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = try VectorIndex(modelID: "test", dimensions: 8, directory: directory)
        try await index.openForWriting()

        var target = [Float](repeating: 0, count: 8)
        target[3] = 1
        var other = [Float](repeating: 0, count: 8)
        other[7] = 1

        try await index.add([(momentID: 42, vector: target), (momentID: 43, vector: other)])
        try await index.save()
        #expect(await index.count == 2)

        // Reopened read-only and memory-mapped — the mode the app searches in,
        // so millions of moments never have to sit in RAM.
        let reopened = try VectorIndex(modelID: "test", dimensions: 8, directory: directory)
        try await reopened.openForSearch()
        let hits = try await reopened.search(target, limit: 1)
        #expect(hits.first?.momentID == 42)
        #expect((hits.first?.similarity ?? 0) > 0.99)
    }

    @Test("Re-indexing a moment replaces its vector instead of duplicating it")
    func reindexReplaces() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-vec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = try VectorIndex(modelID: "test", dimensions: 4, directory: directory)
        try await index.openForWriting()
        try await index.add([(momentID: 1, vector: [1, 0, 0, 0])])
        try await index.add([(momentID: 1, vector: [0, 1, 0, 0])])
        #expect(await index.count == 1)

        let hits = try await index.search([0, 1, 0, 0], limit: 2)
        #expect(hits.count == 1)
        #expect((hits.first?.similarity ?? 0) > 0.99)
    }
}

@Suite("Model registry")
struct ModelTests {
    @Test("Model identifiers are versioned so vectors are never mixed")
    func modelIDsAreVersioned() {
        #expect(MobileCLIPVariant.s0.modelID == "mobileclip-s0-v1")
        #expect(MobileCLIPVariant.s2.modelID == "mobileclip-s2-v1")
        // Different variants must never share an index.
        let ids = Set(MobileCLIPVariant.allCases.map(\.modelID))
        #expect(ids.count == MobileCLIPVariant.allCases.count)
    }

    @Test("Every variant matches the shape of Apple's Core ML export")
    func modelShape() {
        for variant in MobileCLIPVariant.allCases {
            #expect(variant.inputSize == 256)
            #expect(variant.dimensions == 512)
            #expect(variant.similarityFloor < variant.similarityCeiling)
        }
    }
}
