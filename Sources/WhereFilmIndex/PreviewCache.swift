import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
import WhereFilmCore

/// Thumbnails, treated as a budgeted cache rather than storage.
///
/// This is where an index like this actually gets fat. The vectors for millions
/// of moments are gigabytes; a 20 KB JPEG for each of those same moments would be
/// closer to a hundred. So: one poster per asset always, previews for recent and
/// pinned results, and everything else regenerable and evictable.
///
/// The payoff is the feature that makes the product feel like magic — a result
/// you can still *see* while the drive it came from is sitting in a drawer.
public struct PreviewCache: Sendable {
    public struct Budget: Sendable {
        public var maximumBytes: Int64
        public static let fiveGB = Budget(maximumBytes: 5 << 30)
        public static let tenGB = Budget(maximumBytes: 10 << 30)
        public static let twentyFiveGB = Budget(maximumBytes: 25 << 30)
        public static let unlimited = Budget(maximumBytes: .max)

        public init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
    }

    let store: IndexStore
    let directory: URL
    public var budget: Budget
    public var maxPixelSize = 480
    public var jpegQuality = 0.72

    public init(store: IndexStore, directory: URL = AppPaths.previews,
                budget: Budget = .tenGB) {
        self.store = store
        self.directory = directory
        self.budget = budget
    }

    @discardableResult
    public func store(_ image: CGImage, momentID: Int64, assetID: Int64,
                      pinned: Bool = false) throws -> URL? {
        // Shard by asset so a folder never accumulates a million entries.
        let shard = directory.appendingPathComponent(String(format: "%03d", assetID % 512))
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let url = shard.appendingPathComponent("\(momentID).jpg")

        guard let data = Self.jpegData(from: image, maxPixelSize: maxPixelSize,
                                       quality: jpegQuality) else { return nil }
        try data.write(to: url, options: .atomic)

        try store.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO previews (momentID, cachePath, bytes, lastUsedAt, pinned)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(momentID) DO UPDATE SET
                    cachePath = excluded.cachePath, bytes = excluded.bytes,
                    lastUsedAt = excluded.lastUsedAt,
                    pinned = previews.pinned OR excluded.pinned
                """, arguments: [momentID, url.path, Int64(data.count), Date(), pinned])
        }
        return url
    }

    public func url(momentID: Int64) throws -> URL? {
        let path: String? = try store.dbPool.write { db in
            let value = try String.fetchOne(
                db, sql: "SELECT cachePath FROM previews WHERE momentID = ?",
                arguments: [momentID])
            if value != nil {
                try db.execute(sql: "UPDATE previews SET lastUsedAt = ? WHERE momentID = ?",
                               arguments: [Date(), momentID])
            }
            return value
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func totalBytes() throws -> Int64 {
        try store.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT coalesce(sum(bytes), 0) FROM previews") ?? 0
        }
    }

    /// Evicts least-recently-used, unpinned previews until we're back under
    /// budget. Everything evicted can be regenerated from the original — when
    /// the drive is plugged in again.
    @discardableResult
    public func enforceBudget() throws -> Int64 {
        var total = try totalBytes()
        guard total > budget.maximumBytes else { return 0 }

        var freed: Int64 = 0
        while total > budget.maximumBytes {
            let victims: [(Int64, String, Int64)] = try store.dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT momentID, cachePath, bytes FROM previews
                    WHERE pinned = 0 ORDER BY lastUsedAt LIMIT 256
                    """).map { ($0["momentID"], $0["cachePath"], $0["bytes"]) }
            }
            guard !victims.isEmpty else { break }

            for (momentID, path, bytes) in victims {
                try? FileManager.default.removeItem(atPath: path)
                _ = try store.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM previews WHERE momentID = ?",
                                   arguments: [momentID])
                }
                total -= bytes
                freed += bytes
                if total <= budget.maximumBytes { break }
            }
        }
        return freed
    }

    static func jpegData(from image: CGImage, maxPixelSize: Int, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
        let source: CGImage
        if scale < 1, let resized = resize(image, scale: scale) {
            source = resized
        } else {
            source = image
        }

        CGImageDestinationAddImage(destination, source, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func resize(_ image: CGImage, scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
