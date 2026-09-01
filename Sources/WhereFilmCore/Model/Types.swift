import Foundation
import GRDB

// MARK: - Media

public enum MediaType: String, Codable, Sendable, DatabaseValueConvertible {
    case video
    case image
    case audio
}

/// Whether we can reach a file *right now*. The whole point of this enum is that
/// `offline` and `missing` are different things, and neither means "forget what
/// we learned about this asset".
public enum Availability: String, Codable, Sendable, DatabaseValueConvertible {
    /// Volume is mounted and the file is where we left it.
    case online
    /// The volume simply isn't plugged in. Nothing is wrong.
    case offline
    /// Volume is mounted, the path is gone, but the content turned up elsewhere.
    case moved
    /// Volume is mounted, the path is gone, and we can't find the content anywhere.
    case missing
}

/// The four levels of analysis an asset can have. They are independent: an asset
/// can be searchable by transcript before its visual embeddings exist, or the
/// other way around.
public struct IndexLevels: OptionSet, Codable, Sendable, DatabaseValueConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Filename, path, volume, duration, codec, dates, poster. Near-instant.
    public static let metadata = IndexLevels(rawValue: 1 << 0)
    /// Shot detection, keyframes, visual embeddings. Cheap.
    public static let visual = IndexLevels(rawValue: 1 << 1)
    /// Full transcript and OCR of keyframes. Expensive.
    public static let spoken = IndexLevels(rawValue: 1 << 2)
    /// Diarization, face clustering, captions, deep VLM. Opt-in.
    public static let deep = IndexLevels(rawValue: 1 << 3)

    public static let none: IndexLevels = []

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Records

public struct Volume: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "volumes"

    public var volumeUUID: String
    public var name: String
    public var fsType: String?
    public var isOnline: Bool
    public var lastSeenAt: Date
    /// Security-scoped bookmark, so we keep access across launches without
    /// asking for Full Disk Access.
    public var bookmark: Data?

    public init(volumeUUID: String, name: String, fsType: String? = nil,
                isOnline: Bool = true, lastSeenAt: Date = Date(), bookmark: Data? = nil) {
        self.volumeUUID = volumeUUID
        self.name = name
        self.fsType = fsType
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.bookmark = bookmark
    }
}

public struct Asset: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "assets"

    public var assetID: Int64?
    /// Cheap content identity: size ‖ duration ‖ codec ‖ head/middle/tail samples.
    /// Never a path.
    public var contentKey: String
    /// Full-stream hash. Only computed when quick keys collide, and only when idle.
    public var strongKey: String?
    public var mediaType: MediaType
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var createdAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var indexedLevels: IndexLevels
    public var displayName: String
    public var indexedAt: Date

    public init(assetID: Int64? = nil, contentKey: String, strongKey: String? = nil,
                mediaType: MediaType, durationSeconds: Double? = nil,
                width: Int? = nil, height: Int? = nil, createdAt: Date? = nil,
                cameraMake: String? = nil, cameraModel: String? = nil,
                indexedLevels: IndexLevels = .none, displayName: String,
                indexedAt: Date = Date()) {
        self.assetID = assetID
        self.contentKey = contentKey
        self.strongKey = strongKey
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.indexedLevels = indexedLevels
        self.displayName = displayName
        self.indexedAt = indexedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        assetID = inserted.rowID
    }
}

public struct Location: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "locations"

    public var locationID: Int64?
    public var assetID: Int64
    public var volumeUUID: String
    /// Path *relative to the volume root*, so a remount at `/Volumes/Media 1`
    /// changes nothing.
    public var relativePath: String
    public var fileSize: Int64
    public var modifiedAt: Date?
    public var availability: Availability
    public var lastSeenAt: Date

    public init(locationID: Int64? = nil, assetID: Int64, volumeUUID: String,
                relativePath: String, fileSize: Int64, modifiedAt: Date? = nil,
                availability: Availability = .online, lastSeenAt: Date = Date()) {
        self.locationID = locationID
        self.assetID = assetID
        self.volumeUUID = volumeUUID
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.availability = availability
        self.lastSeenAt = lastSeenAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        locationID = inserted.rowID
    }
}

/// A searchable instant. For a photo there is exactly one, spanning [0, 0].
/// For a 30-minute interview there are typically 40–180, not 54,000.
public struct Moment: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "moments"

    public var momentID: Int64?
    public var assetID: Int64
    public var startSeconds: Double
    public var endSeconds: Double
    /// Perceptual hash of the keyframe, used for shot-change detection and
    /// near-duplicate suppression in results.
    public var frameHash: Int64?

    public init(momentID: Int64? = nil, assetID: Int64, startSeconds: Double,
                endSeconds: Double, frameHash: Int64? = nil) {
        self.momentID = momentID
        self.assetID = assetID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.frameHash = frameHash
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        momentID = inserted.rowID
    }
}

public struct TranscriptChunk: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcript_chunks"

    public var chunkID: Int64?
    public var assetID: Int64
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var confidence: Double?
    public var locale: String?

    public init(chunkID: Int64? = nil, assetID: Int64, startSeconds: Double,
                endSeconds: Double, text: String, confidence: Double? = nil,
                locale: String? = nil) {
        self.chunkID = chunkID
        self.assetID = assetID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
        self.locale = locale
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        chunkID = inserted.rowID
    }
}

public struct OCRText: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "ocr_texts"

    public var ocrID: Int64?
    public var momentID: Int64
    public var assetID: Int64
    public var text: String
    public var confidence: Double?

    public init(ocrID: Int64? = nil, momentID: Int64, assetID: Int64,
                text: String, confidence: Double? = nil) {
        self.ocrID = ocrID
        self.momentID = momentID
        self.assetID = assetID
        self.text = text
        self.confidence = confidence
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        ocrID = inserted.rowID
    }
}

// MARK: - Jobs

public enum JobTask: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case metadata      // Level A
    case visual        // Level B
    case transcribe    // Level C
    case ocr           // Level C
    case strongHash    // idle-only disambiguation

    /// Lower runs first.
    public var defaultPriority: Int {
        switch self {
        case .metadata: 0
        case .visual: 10
        case .ocr: 20
        case .transcribe: 30
        case .strongHash: 90
        }
    }
}

public enum JobState: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case running
    case done
    case failed
}

public struct Job: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "jobs"

    public var jobID: Int64?
    public var assetID: Int64
    public var task: JobTask
    public var state: JobState
    public var priority: Int
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(jobID: Int64? = nil, assetID: Int64, task: JobTask,
                state: JobState = .pending, priority: Int? = nil,
                attempts: Int = 0, lastError: String? = nil, updatedAt: Date = Date()) {
        self.jobID = jobID
        self.assetID = assetID
        self.task = task
        self.state = state
        self.priority = priority ?? task.defaultPriority
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        jobID = inserted.rowID
    }
}

// MARK: - Models

/// Embeddings from different models are not comparable. Every vector we store
/// records which model produced it, so swapping models is a background reindex
/// rather than a catastrophe.
public struct ModelRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_registry"

    public var modelID: String
    public var kind: String
    public var revision: String?
    public var dimensions: Int
    public var quantization: String
    public var createdAt: Date

    public init(modelID: String, kind: String, revision: String? = nil,
                dimensions: Int, quantization: String, createdAt: Date = Date()) {
        self.modelID = modelID
        self.kind = kind
        self.revision = revision
        self.dimensions = dimensions
        self.quantization = quantization
        self.createdAt = createdAt
    }
}
