import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WhereFilmCore

/// Vision, run in other processes.
///
/// `VisionGate` documents the reason at length: `RecognizeTextRequest` corrupts
/// memory inside Apple's own framework past roughly three concurrent requests,
/// and again whenever Core ML image work overlaps it. The in-process response was
/// a gate of two with Core ML held exclusive — correct, and it costs most of the
/// machine, because Vision itself scales 4.6× to depth 8 and OCR is about 90% of
/// the visual pass.
///
/// Processes are the way out. The fault is per-process, so N helpers at depth one
/// are N concurrent requests with no shared heap to corrupt, and when Apple's
/// framework does die it takes a 30 MB helper with it instead of the application
/// that was indexing overnight.
///
/// The wire protocol is duplicated by hand in `WhereFilmVisionHelper` rather than
/// shared through a module. That is deliberate: the helper must be able to hold
/// nothing of ours — no database, no model, no opinion — and a shared type is the
/// first step towards it holding all three.
public actor VisionHelperPool {
    public static let shared = VisionHelperPool()

    /// What to ask of one image.
    public struct Request: Encodable, Sendable {
        public var operations: [String]
        public var recognitionLanguages: [String]?
        public var customWords: [String]?
        public var minimumConfidence: Float?
        public var maximumLabels: Int?

        public init(operations: [String], recognitionLanguages: [String]? = nil,
                    customWords: [String]? = nil, minimumConfidence: Float? = nil,
                    maximumLabels: Int? = nil) {
            self.operations = operations
            self.recognitionLanguages = recognitionLanguages
            self.customWords = customWords
            self.minimumConfidence = minimumConfidence
            self.maximumLabels = maximumLabels
        }
    }

    public struct RecognizedText: Decodable, Sendable {
        public var text: String
        public var confidence: Double
    }

    public struct Label: Decodable, Sendable {
        public var identifier: String
        public var confidence: Double
    }

    public struct Face: Decodable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public var quality: Double?
        public var roll: Double?, yaw: Double?, pitch: Double?
        public var leftEyeX: Double?, leftEyeY: Double?
        public var rightEyeX: Double?, rightEyeY: Double?
    }

    public struct Response: Decodable, Sendable {
        public var ok: Bool
        public var error: String?
        public var text: RecognizedText?
        public var labels: [Label]?
        public var faces: [Face]?
    }

    public enum PoolError: Error, LocalizedError {
        case unavailable
        case helperFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "No Vision helper process is available."
            case .helperFailed(let detail): "The Vision helper failed: \(detail)"
            }
        }
    }

    /// How many helpers to run.
    ///
    /// One per performance core, minus headroom for the app itself and for the
    /// Core ML encoding that still happens in-process. Deliberately conservative:
    /// the point is to escape a ceiling of two, not to saturate the machine while
    /// somebody is editing on it.
    public static var recommendedCount: Int {
        if let override = ProcessInfo.processInfo.environment["WHEREFILM_VISION_HELPERS"],
           let value = Int(override) {
            // Zero means "run Vision in this process", which is how the two paths
            // get measured against each other on the same machine and the same
            // library rather than against a memory of last week's numbers.
            return max(0, value)
        }
        let profile = MachineProfile.current
        return max(1, min(4, profile.performanceCores - 1))
    }

    private let count: Int
    private var helpers: [VisionHelper] = []
    private var free: [Int] = []
    private var waiting: [CheckedContinuation<Int, Never>] = []
    private var nextWaiter = 0
    private var started = false
    /// Set once launching has failed, so a machine where the helper is missing
    /// pays for one failed attempt rather than one per frame.
    private var unavailable = false

    public init(count: Int? = nil) {
        let requested = count ?? Self.recommendedCount
        self.count = max(1, requested)
        self.unavailable = requested <= 0
    }

    /// Whether helpers can be used at all. False means callers should run Vision
    /// in-process behind `VisionGate`, exactly as before.
    public func isUsable() -> Bool {
        !unavailable && (started || VisionHelper.executableURL() != nil)
    }

    public func capacity() -> Int { unavailable ? 0 : count }

    public func analyze(imageData: Data, request: Request) async throws -> Response {
        guard !unavailable else { throw PoolError.unavailable }
        try start()
        let index = await acquire()
        defer { release(index) }

        do {
            return try await helpers[index].send(request: request, imageData: imageData)
        } catch {
            // A helper that dies is replaced, and the work is retried once. This
            // is the whole reason for the design: Apple's crash becomes a retry
            // instead of a lost night of indexing.
            helpers[index].terminate()
            guard let replacement = try? VisionHelper() else {
                unavailable = true
                throw PoolError.unavailable
            }
            helpers[index] = replacement
            return try await helpers[index].send(request: request, imageData: imageData)
        }
    }

    /// Convenience for callers holding a decoded frame.
    public func analyze(image: CGImage, request: Request) async throws -> Response {
        guard let data = Self.encode(image) else {
            throw PoolError.helperFailed("could not encode the frame")
        }
        return try await analyze(imageData: data, request: request)
    }

    /// JPEG at quality 0.95, which is the cheapest way to move a frame between
    /// processes without paying for it in recall.
    ///
    /// PNG is lossless and roughly ten times the bytes and the encode time; raw
    /// pixels are 4 MB a frame. At 0.95 the artefacts are far below what the
    /// text recogniser can notice — the OCR cases in the evaluation set score
    /// identically either way — and a 1024 px frame lands around 150 KB.
    static func encode(_ image: CGImage, quality: CGFloat = 0.95) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public func shutdown() {
        for helper in helpers { helper.terminate() }
        helpers.removeAll()
        free.removeAll()
        started = false
    }

    private func start() throws {
        guard !started else { return }
        guard VisionHelper.executableURL() != nil else {
            unavailable = true
            throw PoolError.unavailable
        }
        for _ in 0..<count {
            guard let helper = try? VisionHelper() else { continue }
            helpers.append(helper)
        }
        guard !helpers.isEmpty else {
            unavailable = true
            throw PoolError.unavailable
        }
        free = Array(helpers.indices)
        started = true
    }

    private func acquire() async -> Int {
        if nextWaiter == waiting.count, let index = free.popLast() { return index }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func release(_ index: Int) {
        if nextWaiter < waiting.count {
            let continuation = waiting[nextWaiter]
            nextWaiter += 1
            continuation.resume(returning: index)
            if nextWaiter == waiting.count {
                waiting.removeAll(keepingCapacity: true)
                nextWaiter = 0
            }
            return
        }
        free.append(index)
    }
}

/// One helper process, and the pipe to it.
///
/// Requests are serialised per helper by construction: the protocol is one frame
/// in, one frame out, so a helper is busy or it is not. Concurrency comes from
/// having several, which is exactly the property that makes the crash survivable.
final class VisionHelper: @unchecked Sendable {
    private let process = Process()
    private let toHelper = Pipe()
    private let fromHelper = Pipe()
    /// The blocking pipe I/O has to live somewhere that is not a cooperative
    /// thread. Swift's pool does not grow to cover blocked threads, and this is
    /// the same lesson Vision's internal queue taught the indexer.
    private let queue: DispatchQueue

    init() throws {
        guard let executable = Self.executableURL() else {
            throw VisionHelperPool.PoolError.unavailable
        }
        queue = DispatchQueue(label: "gt.roo.wherefilm.vision-helper", qos: .utility)
        process.executableURL = executable
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        // Let the helper's own diagnostics reach the terminal rather than
        // disappearing; a silent helper is undebuggable.
        process.standardError = FileHandle.standardError
        try process.run()
    }

    /// Where the helper lives, in the order the running program should look.
    ///
    /// Next to the executable covers both cases that matter: the app bundle,
    /// where `make-app.sh` puts it, and the SwiftPM build directory, where the
    /// CLI and the tests run from.
    static func executableURL() -> URL? {
        let name = "wherefilm-vision-helper"
        var candidates: [URL] = []
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main.appendingPathComponent(name))
            candidates.append(main.appendingPathComponent("../Helpers/\(name)")
                .standardizedFileURL)
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent(name))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func send(request: VisionHelperPool.Request, imageData: Data) async throws
        -> VisionHelperPool.Response {
        let specData = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard process.isRunning else {
                        throw VisionHelperPool.PoolError.helperFailed("the helper is not running")
                    }
                    let input = toHelper.fileHandleForWriting
                    try write(specData, to: input)
                    try write(imageData, to: input)
                    let payload = try readFrame()
                    let response = try JSONDecoder().decode(
                        VisionHelperPool.Response.self, from: payload)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? toHelper.fileHandleForWriting.close()
        try? fromHelper.fileHandleForReading.close()
    }

    private func write(_ payload: Data, to handle: FileHandle) throws {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        try handle.write(contentsOf: framed)
    }

    private func readFrame() throws -> Data {
        let handle = fromHelper.fileHandleForReading
        guard let header = try readExactly(4, from: handle) else {
            throw VisionHelperPool.PoolError.helperFailed("the helper closed its output")
        }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 64 * 1024 * 1024,
              let payload = try readExactly(Int(length), from: handle) else {
            throw VisionHelperPool.PoolError.helperFailed("truncated reply")
        }
        return payload
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count),
                  !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }
}
