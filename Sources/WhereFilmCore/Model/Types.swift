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

/// One label the classifier put on one moment.
public struct LabelRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "labels"

    public var labelID: Int64?
    public var momentID: Int64
    public var assetID: Int64
    public var identifier: String
    public var confidence: Double
    /// Which classifier produced it. Same rule as `embeddings.modelID`: a
    /// taxonomy that improves should be re-derivable, not frozen.
    public var source: String

    public init(labelID: Int64? = nil, momentID: Int64, assetID: Int64,
                identifier: String, confidence: Double, source: String) {
        self.labelID = labelID
        self.momentID = momentID
        self.assetID = assetID
        self.identifier = identifier
        self.confidence = confidence
        self.source = source
    }

    /// How the label reads in the text index. Vision's identifiers are
    /// underscored — `printed_page`, `sports_equipment` — and nobody searches
    /// that way.
    public var searchableText: String {
        identifier.replacingOccurrences(of: "_", with: " ")
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
    /// Which speech engine produced this, so a library transcribed by the
    /// fallback can be found and redone on better hardware.
    public var engine: String?

    public init(chunkID: Int64? = nil, assetID: Int64, startSeconds: Double,
                endSeconds: Double, text: String, confidence: Double? = nil,
                locale: String? = nil, engine: String? = nil) {
        self.engine = engine
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
    /// Who was speaking. Level D: opt-in, Apple silicon only, and the only task
    /// whose models are not already on the machine.
    case diarize
    case strongHash    // idle-only disambiguation

    /// Lower runs first.
    public var defaultPriority: Int {
        switch self {
        case .metadata: 0
        case .visual: 10
        case .ocr: 20
        case .transcribe: 30
        // After transcription: it is more expensive, less essential, and only
        // meaningful once there is a transcript to attribute.
        case .diarize: 40
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

// MARK: - People

/// One detected face, with the vector that decides who it belongs to.
///
/// `modelID` is mandatory for the same reason it is on `embeddings`: face
/// vectors from different models are never comparable, and a better model has to
/// be a background reindex rather than a destructive migration. It is also what
/// makes the current, weak descriptor an honest starting point instead of a
/// commitment.
public struct FaceRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "faces"

    public var faceID: Int64?
    public var momentID: Int64
    public var assetID: Int64
    public var seconds: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var quality: Double?
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var modelID: String
    public var dimensions: Int
    public var quantization: String
    public var scale: Double
    public var vector: Data
    public var personID: Int64?
    public var assignedBy: String

    public init(faceID: Int64? = nil, momentID: Int64, assetID: Int64, seconds: Double,
                x: Double, y: Double, width: Double, height: Double,
                quality: Double? = nil, roll: Double? = nil, yaw: Double? = nil,
                pitch: Double? = nil, modelID: String, dimensions: Int,
                quantization: String = VectorQuantization.int8.rawValue, scale: Double = 1,
                vector: Data, personID: Int64? = nil, assignedBy: String = "auto") {
        self.faceID = faceID
        self.momentID = momentID
        self.assetID = assetID
        self.seconds = seconds
        self.x = x; self.y = y; self.width = width; self.height = height
        self.quality = quality
        self.roll = roll; self.yaw = yaw; self.pitch = pitch
        self.modelID = modelID
        self.dimensions = dimensions
        self.quantization = quantization
        self.scale = scale
        self.vector = vector
        self.personID = personID
        self.assignedBy = assignedBy
    }

    /// True when a person put this face where it is. Automatic passes must not
    /// move it.
    public var isPlacedByUser: Bool { assignedBy == "user" }

    public var decodedVector: [Float] {
        VectorCodec.decode(vector, scale: scale,
                           quantization: VectorQuantization(rawValue: quantization) ?? .int8)
    }
}

/// A cluster of faces that are probably the same person, named or not.
public struct Person: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "people"

    public var personID: Int64?
    public var displayName: String?
    public var isNamed: Bool
    public var centroid: Data?
    public var faceCount: Int
    public var coverFaceID: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(personID: Int64? = nil, displayName: String? = nil, isNamed: Bool = false,
                centroid: Data? = nil, faceCount: Int = 0, coverFaceID: Int64? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.personID = personID
        self.displayName = displayName
        self.isNamed = isNamed
        self.centroid = centroid
        self.faceCount = faceCount
        self.coverFaceID = coverFaceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var decodedCentroid: [Float]? {
        centroid.map { VectorCodec.decodeFloat32($0) }
    }
}

/// Where a person appears, as an interval. The product's answer to
/// "¿en qué minuto sale Jorge?" is a range, not an instant, because a person is
/// on screen for a while and a single timestamp would be a worse answer.
public struct PersonAppearance: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "person_appearances"

    public var id: Int64?
    public var personID: Int64
    public var assetID: Int64
    public var startSeconds: Double
    public var endSeconds: Double
    public var confidence: Double
    /// 'face', 'voice' or 'both'.
    public var source: String

    public init(id: Int64? = nil, personID: Int64, assetID: Int64, startSeconds: Double,
                endSeconds: Double, confidence: Double, source: String = "face") {
        self.id = id
        self.personID = personID
        self.assetID = assetID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
        self.source = source
    }
}

/// A correction somebody made, kept so no automatic pass can quietly undo it.
public struct PersonFeedback: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "people_feedback"

    public enum Kind: String, Codable, Sendable {
        case merge, split, name, ignore
    }

    public var id: Int64?
    public var kind: String
    public var aPersonID: Int64?
    public var bPersonID: Int64?
    public var faceID: Int64?
    public var createdAt: Date

    public init(id: Int64? = nil, kind: Kind, aPersonID: Int64? = nil,
                bPersonID: Int64? = nil, faceID: Int64? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind.rawValue
        self.aPersonID = aPersonID
        self.bPersonID = bPersonID
        self.faceID = faceID
        self.createdAt = createdAt
    }
}

/// A voice the library has heard more than once.
public struct Voice: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "voices"

    public var voiceID: Int64?
    public var personID: Int64?
    public var centroid: Data?
    public var segmentCount: Int
    public var modelID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(voiceID: Int64? = nil, personID: Int64? = nil, centroid: Data? = nil,
                segmentCount: Int = 0, modelID: String,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.voiceID = voiceID
        self.personID = personID
        self.centroid = centroid
        self.segmentCount = segmentCount
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var decodedCentroid: [Float]? {
        centroid.map { VectorCodec.decodeFloat32($0) }
    }
}

/// One stretch of one file where one person was speaking.
public struct VoiceSegment: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "voice_segments"

    public var segmentID: Int64?
    public var assetID: Int64
    public var startSeconds: Double
    public var endSeconds: Double
    /// The diarizer's label *within this file*: "Speaker 1" here has nothing to
    /// do with "Speaker 1" in the next file. Clustering the embeddings is what
    /// gives those labels meaning across a library.
    public var localSpeaker: String
    public var voiceID: Int64?
    public var modelID: String
    public var dimensions: Int
    public var quantization: String
    public var scale: Double
    public var vector: Data?
    public var confidence: Double?

    public init(segmentID: Int64? = nil, assetID: Int64, startSeconds: Double,
                endSeconds: Double, localSpeaker: String, voiceID: Int64? = nil,
                modelID: String, dimensions: Int = 0,
                quantization: String = VectorQuantization.int8.rawValue,
                scale: Double = 1, vector: Data? = nil, confidence: Double? = nil) {
        self.segmentID = segmentID
        self.assetID = assetID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.localSpeaker = localSpeaker
        self.voiceID = voiceID
        self.modelID = modelID
        self.dimensions = dimensions
        self.quantization = quantization
        self.scale = scale
        self.vector = vector
        self.confidence = confidence
    }

    public var decodedVector: [Float]? {
        guard let vector, dimensions > 0 else { return nil }
        return VectorCodec.decode(vector, scale: scale,
                                  quantization: VectorQuantization(rawValue: quantization) ?? .int8)
    }
}
