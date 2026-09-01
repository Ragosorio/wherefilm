import Foundation
import CryptoKit

/// Content identity for media files.
///
/// A path can never be an identity: the file gets renamed, the folder gets
/// reorganised, and macOS is free to remount a volume at a different path. But
/// hashing 30 GB per file would turn the first scan of a few hundred terabytes
/// into a multi-day I/O job, so identity happens in two tiers.
public enum ContentKey {
    /// How much of the file each sampled region reads.
    static let sampleBytes = 1 << 20   // 1 MiB
    /// Below this size we just hash the whole thing — it's cheaper than seeking.
    static let fullHashThreshold: Int64 = 8 << 20   // 8 MiB

    /// Tier 1 — milliseconds, never reads the middle 30 GB.
    ///
    /// Mixes size, duration and codec with three 1 MiB samples (head, middle,
    /// tail). For camera-original media the practical collision rate is nil: two
    /// different clips essentially never share byte-identical head/middle/tail
    /// *and* the same length.
    public static func quick(
        url: URL,
        fileSize: Int64,
        durationSeconds: Double? = nil,
        codec: String? = nil
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("wf-quick-v1".utf8))
        hasher.update(data: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })

        // Duration is rounded to 1 ms so that trivial container rewrites don't
        // produce a different identity.
        if let durationSeconds, durationSeconds.isFinite {
            let millis = Int64((durationSeconds * 1000).rounded())
            hasher.update(data: withUnsafeBytes(of: millis.littleEndian) { Data($0) })
        }
        if let codec {
            hasher.update(data: Data(codec.utf8))
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if fileSize <= fullHashThreshold {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            let offsets: [Int64] = [
                0,
                max(0, fileSize / 2 - Int64(sampleBytes) / 2),
                max(0, fileSize - Int64(sampleBytes)),
            ]
            for offset in offsets {
                try handle.seek(toOffset: UInt64(offset))
                if let chunk = try handle.read(upToCount: sampleBytes) {
                    hasher.update(data: chunk)
                }
            }
        }

        return "q1:" + hasher.finalize().hexString
    }

    /// Tier 2 — full stream hash. Only worth doing when two quick keys collide,
    /// when we are chasing a file across volumes, or when the machine is idle and
    /// the user asked for verification.
    public static func strong(url: URL, progress: (@Sendable (Int64) -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("wf-strong-v1".utf8))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            read += Int64(chunk.count)
            progress?(read)
        }
        return "s1:" + hasher.finalize().hexString
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
