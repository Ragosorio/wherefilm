import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import WhereFilmCore

/// Everything Level A needs, read straight from the container.
public struct MediaInfo: Sendable {
    public var mediaType: MediaType
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var createdAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var codec: String?
    public var hasAudio: Bool

    public var cameraDescription: String? {
        [cameraMake, cameraModel].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }
}

/// Reads media metadata through AVFoundation rather than shelling out to ffmpeg.
///
/// For everything macOS decodes natively — MOV, MP4, HEVC, H.264, ProRes — there
/// is no architectural reason to spawn an external process per clip. FFmpeg stays
/// a sensible *fallback* for exotic codecs; making it the primary path would add
/// another binary, more packaging, more licensing surface and a distinctly
/// less-Mac feel.
public struct MediaProbe: Sendable {
    public init() {}

    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "mpg", "mpeg", "webm", "braw", "r3d",
    ]
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "webp", "gif",
    ]
    public static let audioExtensions: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"]

    public static func mediaType(for url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    public func probe(url: URL) async throws -> MediaInfo {
        switch Self.mediaType(for: url) {
        case .image: probeImage(url: url)
        case .audio: try await probeAV(url: url, mediaType: .audio)
        default: try await probeAV(url: url, mediaType: .video)
        }
    }

    private func probeAV(url: URL, mediaType: MediaType) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])

        let duration = try? await asset.load(.duration)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        var width: Int?
        var height: Int?
        var codec: String?
        if let track = videoTracks.first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let oriented = size.applying(transform)
                width = Int(abs(oriented.width))
                height = Int(abs(oriented.height))
            }
            if let descriptions = try? await track.load(.formatDescriptions),
               let first = descriptions.first {
                codec = fourCCString(CMFormatDescriptionGetMediaSubType(first))
            }
        }

        var createdAt: Date?
        var make: String?
        var model: String?
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyCreationDate:
                    if let date = try? await item.load(.dateValue) {
                        createdAt = date
                    } else if let string = (try? await item.load(.stringValue)) ?? nil {
                        createdAt = Self.parseDate(string)
                    }
                case .commonKeyMake:
                    make = (try? await item.load(.stringValue)) ?? nil
                case .commonKeyModel:
                    model = (try? await item.load(.stringValue)) ?? nil
                default:
                    break
                }
            }
        }
        if createdAt == nil {
            createdAt = try? await asset.load(.creationDate)?.load(.dateValue)
        }
        if createdAt == nil {
            createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }

        let seconds = duration.map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil }
        return MediaInfo(
            mediaType: videoTracks.isEmpty && !audioTracks.isEmpty ? .audio : mediaType,
            durationSeconds: seconds,
            width: width, height: height,
            createdAt: createdAt,
            cameraMake: make, cameraModel: model,
            codec: codec,
            hasAudio: !audioTracks.isEmpty)
    }

    private func probeImage(url: URL) -> MediaInfo {
        var info = MediaInfo(mediaType: .image, durationSeconds: 0, width: nil, height: nil,
                             createdAt: nil, cameraMake: nil, cameraModel: nil,
                             codec: url.pathExtension.lowercased(), hasAudio: false)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return info }

        info.width = properties[kCGImagePropertyPixelWidth] as? Int
        info.height = properties[kCGImagePropertyPixelHeight] as? Int
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            info.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.createdAt = Self.parseExifDate(original)
        }
        if info.createdAt == nil {
            info.createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return info
    }

    private func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string) ?? parseExifDate(string)
    }

    static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
