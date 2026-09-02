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

    @Test("Very long videos spread the frame budget across the whole file")
    func longVideosCoverTheirDuration() {
        var options = KeyframeSampler.Options()
        options.intervalSeconds = 5
        options.maxFramesPerAsset = 4_000
        let sampler = KeyframeSampler(options: options)

        #expect(sampler.samplingInterval(durationSeconds: 600) == 5)
        // Twelve hours no longer means "only index the first 5 h 33 min".
        #expect(abs(sampler.samplingInterval(durationSeconds: 43_200) - 10.8) < 0.001)
    }

    @Test("An unchanged catalog location is safe to skip without reading media")
    func unchangedRevisionFastPath() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let location = Location(assetID: 1, volumeUUID: "V", relativePath: "film.mov",
                                fileSize: 8_000_000_000, modifiedAt: date)

        #expect(LibraryScanner.isSameRevision(location, fileSize: 8_000_000_000,
                                              modifiedAt: date))
        #expect(!LibraryScanner.isSameRevision(location, fileSize: 8_000_000_001,
                                               modifiedAt: date))
        #expect(!LibraryScanner.isSameRevision(location, fileSize: 8_000_000_000,
                                               modifiedAt: date.addingTimeInterval(1)))
    }

    @Test("A repeat scan never opens an unchanged eight-gigabyte file")
    func repeatScanSkipsHugeMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-huge-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // This is sparse: it has an 8 GB logical size but consumes no 8 GB copy.
        // It is intentionally not a valid movie. If the repeat scan touches the
        // media probe, the test fails; the revision fast path must be enough.
        let file = root.appendingPathComponent("archive.mov")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8_000_000_000)
        try handle.close()

        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(try #require(values.fileSize))
        let modifiedAt = try #require(values.contentModificationDate)
        let registry = VolumeRegistry()
        let resolved = try #require(registry.resolve(file))
        let store = try IndexStore.inMemory()
        let asset = try store.insert(Asset(contentKey: "seed:huge", mediaType: .video,
                                           displayName: file.lastPathComponent))
        let assetID = try #require(asset.assetID)
        try store.upsertVolume(Volume(volumeUUID: resolved.volume.uuid,
                                      name: resolved.volume.name))
        try store.upsertLocation(Location(
            assetID: assetID,
            volumeUUID: resolved.volume.uuid,
            relativePath: resolved.relativePath,
            fileSize: size,
            modifiedAt: modifiedAt))

        let report = try await LibraryScanner(store: store, volumes: registry).scan(root: root)
        #expect(report.filesSeen == 1)
        #expect(report.rebound == 1)
        #expect(report.errors.isEmpty)
    }
}

private actor GateProbe {
    private var active = 0
    private var highWaterMark = 0
    private var completed = 0

    func enter() {
        active += 1
        highWaterMark = max(highWaterMark, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }

    func result() -> (peak: Int, completed: Int) { (highWaterMark, completed) }
}

@Suite("Vision request gate")
struct VisionGateTests {
    @Test("Thousands of queued OCR requests stay bounded and all make progress")
    func boundedProgress() async {
        let gate = VisionGate(limit: 2)
        let probe = GateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    await gate.run {
                        await probe.enter()
                        try? await Task.sleep(for: .microseconds(100))
                        await probe.leave()
                    }
                }
            }
        }

        let result = await probe.result()
        #expect(result.peak <= 2)
        #expect(result.completed == 200)
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

    @Test("Battery keeps the library becoming searchable")
    func batteryStillIndexes() {
        // The old policy dropped to metadata-only on battery, and the effect on
        // a laptop was an index that never became searchable at all: files
        // counted, zero moments, forever. Visual and OCR are exactly the two
        // tasks that turn a file into something findable, so they must survive
        // being unplugged.
        var settings = ResourceGovernor.Settings()
        settings.mode = .smart
        let decision = ResourceGovernor(settings: settings).decide()

        if decision.reason == .onBattery {
            #expect(decision.allowedTasks.contains(.visual))
            #expect(decision.allowedTasks.contains(.ocr))
            // Transcription is the genuinely heavy one and still waits for power.
            #expect(!decision.allowedTasks.contains(.transcribe))
            #expect(decision.concurrency >= 1)
        }
    }

    @Test("Concurrency stays within the machine, not within an old guess")
    func concurrencyStaysBounded() {
        // This used to assert a ceiling of 4, from the theory that workers
        // blocking inside GRDB and AVFoundation would deadlock the cooperative
        // pool. Measured, that ceiling cost roughly half the throughput on a
        // photo library and prevented the machine from ever filling Vision's
        // queue. What still has to hold is that the width is bounded by the
        // hardware rather than unbounded.
        var settings = ResourceGovernor.Settings()
        settings.mode = .fullSpeed
        let decision = ResourceGovernor(settings: settings).decide()
        #expect(decision.concurrency >= 1)
        #expect(decision.concurrency <= max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    @Test("Vision stays under the depth where TextRecognition corrupts memory")
    func visionGateHonoursTheCrashCeiling() {
        // Not a tuning preference: above roughly three concurrent
        // RecognizeTextRequests, Apple's framework segfaults while releasing
        // recognition results, and it also objects to Core ML or ImageIO running
        // alongside. Raising this ceiling needs a fresh stress run, not a hunch.
        #expect(VisionGate.crashCeiling == 2)
        #expect(VisionGate.recommendedLimit <= VisionGate.crashCeiling)
        #expect(VisionGate.recommendedLimit >= 1)
    }

    @Test("Heavy and light work share one memory ceiling")
    func budgetBoundsFramesNotJobs() async {
        // A video pass holds a whole sampler batch; a photo holds one frame. The
        // budget is what keeps peak memory from depending on which of those the
        // queue happens to be full of.
        let budget = WorkBudget(capacity: 4)
        let active = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await budget.run(cost: 3) {
                        let peak = await active.enter()
                        #expect(peak <= 1, "two cost-3 jobs must not share a budget of 4")
                        try? await Task.sleep(for: .milliseconds(5))
                        await active.leave()
                    }
                }
            }
        }
        // A job larger than the whole budget still runs, alone, rather than
        // deadlocking forever waiting for space that can never exist.
        let ran = await budget.run(cost: 999) { true }
        #expect(ran)
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


/// Counts how many tasks are inside a budgeted region at once.
private actor Counter {
    private var current = 0
    func enter() -> Int { current += 1; return current }
    func leave() { current -= 1 }
}
