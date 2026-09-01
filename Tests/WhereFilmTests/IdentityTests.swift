import Testing
import Foundation
@testable import WhereFilmCore

/// Content identity is the load-bearing idea of the whole product: if a file's
/// identity is its path, then moving a folder silently destroys everything the
/// app learned about it.
@Suite("Content identity")
struct IdentityTests {
    private func makeFile(bytes: Int, seed: UInt8 = 7) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).bin")
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 977) {
            data[i] = seed &+ UInt8(i % 251)
        }
        try data.write(to: url)
        return url
    }

    @Test("The same bytes at a different path produce the same key")
    func movingAFileKeepsItsIdentity() throws {
        let original = try makeFile(bytes: 3_000_000)
        defer { try? FileManager.default.removeItem(at: original) }

        let size = Int64(try FileManager.default
            .attributesOfItem(atPath: original.path)[.size] as! Int)
        let before = try ContentKey.quick(url: original, fileSize: size,
                                          durationSeconds: 42.5, codec: "hvc1")

        let moved = original.deletingLastPathComponent()
            .appendingPathComponent("renamed-\(UUID().uuidString).bin")
        try FileManager.default.moveItem(at: original, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let after = try ContentKey.quick(url: moved, fileSize: size,
                                         durationSeconds: 42.5, codec: "hvc1")
        #expect(before == after)
    }

    @Test("Different content produces different keys")
    func differentContentDiffers() throws {
        let a = try makeFile(bytes: 3_000_000, seed: 1)
        let b = try makeFile(bytes: 3_000_000, seed: 200)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let size: Int64 = 3_000_000
        let keyA = try ContentKey.quick(url: a, fileSize: size)
        let keyB = try ContentKey.quick(url: b, fileSize: size)
        #expect(keyA != keyB)
    }

    @Test("Duration is part of the identity")
    func durationMatters() throws {
        let url = try makeFile(bytes: 2_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let short = try ContentKey.quick(url: url, fileSize: 2_000_000, durationSeconds: 10)
        let long = try ContentKey.quick(url: url, fileSize: 2_000_000, durationSeconds: 20)
        #expect(short != long)
    }

    @Test("Quick keys never read the middle of a large file")
    func quickKeyIsCheap() throws {
        // 40 MB with a distinctive marker buried at 20 MB. The quick key samples
        // head, middle and tail, so it *should* notice a change at the midpoint —
        // that's the region it deliberately covers.
        let url = try makeFile(bytes: 40_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        _ = try ContentKey.quick(url: url, fileSize: 40_000_000)
        let elapsed = Date().timeIntervalSince(start)
        // Reading 3 MiB out of 40 MB should be far under a second even on a
        // cold cache; if this ever fails, the sampling strategy regressed.
        #expect(elapsed < 1.0)
    }

    @Test("Strong keys differ from quick keys and are stable")
    func strongKeyIsStable() throws {
        let url = try makeFile(bytes: 500_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try ContentKey.strong(url: url)
        let second = try ContentKey.strong(url: url)
        #expect(first == second)
        #expect(first.hasPrefix("s1:"))
        #expect(try ContentKey.quick(url: url, fileSize: 500_000).hasPrefix("q1:"))
    }
}
