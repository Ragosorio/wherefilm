import Foundation
import AVFoundation
import CoreGraphics
import WhereFilmCore

public struct SampledFrame: @unchecked Sendable {
    public let seconds: Double
    public let image: CGImage
    /// 64-bit difference hash of the frame, used for shot detection here and for
    /// near-duplicate suppression in results later.
    public let hash: UInt64
}

/// Picks the handful of frames per video that are actually worth embedding.
///
/// A 30-minute clip at 30 fps holds 54,000 frames and the overwhelming majority
/// are redundant: an interview is the same person in the same chair for minutes
/// at a time. Embedding all of them would cost a fortune and add almost no
/// information.
///
/// The strategy is periodic sampling plus a very cheap visual-change test:
/// static material stores few moments, a music video with hard cuts stores many.
public struct KeyframeSampler: Sendable {
    public struct Options: Sendable {
        /// How often to look at the video at all.
        public var intervalSeconds: Double = 5
        /// Hamming distance (0–64) between consecutive dHashes above which we
        /// treat the frame as a new shot. Lower keeps more frames.
        public var changeThreshold: Int = 12
        /// Frames handed to Core ML at a time.
        public var batchSize: Int = 16
        /// Safety net so one pathological file can't blow up the index.
        public var maxFramesPerAsset: Int = 4000
        /// Longest side handed to the encoder. MobileCLIP wants 256×256 anyway.
        public var maximumSize = CGSize(width: 320, height: 320)

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Streams keyframes in batches so that a three-hour file never materialises
    /// thousands of CGImages at once.
    public func sampleVideo(
        url: URL,
        durationSeconds: Double,
        isolation: isolated (any Actor)? = #isolation,
        onBatch: ([SampledFrame]) async throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = options.maximumSize
        // Generous tolerance means the decoder can hand us the nearest existing
        // keyframe instead of decoding forward to an exact instant. For semantic
        // search a frame half a second away is the same frame.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.6, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.6, preferredTimescale: 600)

        var times: [CMTime] = []
        var t = 0.0
        while t < durationSeconds && times.count < options.maxFramesPerAsset {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += options.intervalSeconds
        }
        if times.isEmpty {
            times = [CMTime(seconds: 0, preferredTimescale: 600)]
        }

        var batch: [SampledFrame] = []
        var previousHash: UInt64?

        for await result in generator.images(for: times) {
            guard let (image, actualTime) = try? (result.image, result.actualTime) else { continue }
            let hash = Self.differenceHash(image)

            // Keep the first frame unconditionally; after that only when the
            // picture actually changed.
            if let previous = previousHash,
               Self.hammingDistance(previous, hash) < options.changeThreshold {
                continue
            }
            previousHash = hash

            batch.append(SampledFrame(
                seconds: CMTimeGetSeconds(actualTime), image: image, hash: hash))
            if batch.count >= options.batchSize {
                try await onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await onBatch(batch) }
    }

    /// A photo is just a video with exactly one moment.
    public func sampleImage(url: URL) throws -> SampledFrame? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return SampledFrame(seconds: 0, image: image, hash: Self.differenceHash(image))
    }

    /// Turns kept keyframes into closed intervals. A moment runs until the next
    /// visual change, which is what makes "jump to 14:12" mean something.
    public static func moments(assetID: Int64, frames: [(seconds: Double, hash: UInt64)],
                               durationSeconds: Double) -> [Moment] {
        guard !frames.isEmpty else { return [] }
        return frames.enumerated().map { index, frame in
            let end = index + 1 < frames.count ? frames[index + 1].seconds : max(durationSeconds, frame.seconds)
            return Moment(assetID: assetID,
                          startSeconds: frame.seconds,
                          endSeconds: max(end, frame.seconds),
                          frameHash: Int64(bitPattern: frame.hash))
        }
    }

    // MARK: - Perceptual hash

    /// dHash: downscale to 9×8 greyscale and record, for each row, whether each
    /// pixel is brighter than the one to its right. Cheap, and robust to the
    /// compression noise and exposure drift that would fool a raw pixel diff.
    public static func differenceHash(_ image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
