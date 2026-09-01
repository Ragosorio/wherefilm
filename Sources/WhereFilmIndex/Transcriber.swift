import Foundation
import AVFoundation
import Speech
import WhereFilmCore

public struct TranscriptSegment: Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let confidence: Double?
}

public enum TranscriptionError: Error, LocalizedError {
    case noAudioTrack
    case localeUnsupported(String)
    case modelUnavailable
    case audioFormatUnavailable

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "The file has no audio track."
        case .localeUnsupported(let id): "SpeechTranscriber does not support the locale \(id)."
        case .modelUnavailable: "The on-device speech model is not installed and could not be downloaded."
        case .audioFormatUnavailable: "Could not negotiate an audio format with SpeechAnalyzer."
        }
    }
}

/// Speech-to-text with timestamps, using the model macOS already ships.
///
/// `SpeechTranscriber` is designed for exactly this workload — long-form
/// recordings, meetings, interviews — runs on-device, and its model is managed by
/// the system: it does not inflate the app bundle and it does not sit in the
/// app's memory the way a packaged Whisper build would.
///
/// The audio is streamed out of the video, transcribed, and thrown away. What
/// remains is plain text with time ranges, which is microscopic next to ProRes.
public struct Transcriber: Sendable {
    public struct Options: Sendable {
        public var locale: Locale
        /// Target length of a stored transcript chunk. Long enough to carry
        /// meaning, short enough that jumping to it lands on the right moment.
        public var chunkSeconds: Double = 12
        /// Ask the system to download the language model if it isn't installed.
        public var allowModelDownload = true
        /// Speech work is maintenance work. It should never outrank the editor.
        public var priority: TaskPriority = .background

        public init(locale: Locale = Locale.current) {
            self.locale = locale
        }
    }

    public var options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Locales the system can transcribe, whether or not the assets are
    /// downloaded yet. Always ask at runtime rather than hardcoding a list.
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public func transcribe(url: URL) async throws -> [TranscriptSegment] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.locale) else {
            throw TranscriptionError.localeUnsupported(options.locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            // `audioTimeRange` is the whole point: without it we would know what
            // was said but not when, and "jump to 14:16" would be impossible.
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        try await ensureModelInstalled(for: transcriber, locale: locale)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatUnavailable
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: options.priority, modelRetention: .whileInUse))

        // Collect results while the audio is still being pushed in.
        let collector = Task {
            var collected: [(CMTimeRange, String, Double?)] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                collected.append((result.range, text, confidence(of: result.text)))
            }
            return collected
        }

        do {
            try await analyzer.start(inputSequence: stream)
            try await pumpAudio(url: url, into: continuation, format: analyzerFormat)
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let results = try await collector.value
        return chunk(results)
    }

    // MARK: - Model assets

    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .downloading:
            // Someone else is already fetching it; let them finish.
            break
        case .supported:
            guard options.allowModelDownload else { throw TranscriptionError.modelUnavailable }
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw TranscriptionError.localeUnsupported(locale.identifier)
        @unknown default:
            break
        }
        // Reserving keeps the locale's assets from being reclaimed mid-run.
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Audio

    /// Reads the audio track straight out of the container, converts it to the
    /// format the analyzer asked for, and streams it. No temporary audio file,
    /// no second copy of the sound on disk.
    private func pumpAudio(url: URL, into continuation: AsyncStream<AnalyzerInput>.Continuation,
                           format analyzerFormat: AVAudioFormat) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analyzerFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: analyzerFormat.sampleRate,
            channels: 1,
            interleaved: false) else {
            throw TranscriptionError.audioFormatUnavailable
        }
        let converter = sourceFormat == analyzerFormat
            ? nil
            : AVAudioConverter(from: sourceFormat, to: analyzerFormat)

        // Timestamps are derived from how many frames we've handed over, not
        // from the reader's presentation times. Format conversion changes the
        // frame count, and the analyzer rejects input whose timestamps overlap
        // or go backwards — a counter at the analyzer's own sample rate cannot
        // drift.
        var framePosition: Int64 = 0
        let timescale = CMTimeScale(analyzerFormat.sampleRate)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let buffer = Self.pcmBuffer(from: sampleBuffer, format: sourceFormat) else { continue }
            let outputBuffer = try Self.convert(buffer, using: converter, to: analyzerFormat)
            guard outputBuffer.frameLength > 0 else { continue }

            continuation.yield(AnalyzerInput(
                buffer: outputBuffer,
                bufferStartTime: CMTime(value: framePosition, timescale: timescale)))
            framePosition += Int64(outputBuffer.frameLength)
            await Task.yield()
        }

        if reader.status == .failed, let error = reader.error { throw error }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let byteCount = frameCount * MemoryLayout<Float>.size
        let status = CMBlockBufferCopyDataBytes(
            blockBuffer, atOffset: 0, dataLength: byteCount,
            destination: destination)
        return status == kCMBlockBufferNoErr ? buffer : nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter?,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.audioFormatUnavailable
        }
        // The converter's callback is invoked synchronously, but the compiler
        // can't see that, so the "already handed over" flag lives in a box.
        let state = ConversionState(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let pending = state.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }
        return output
    }

    // MARK: - Chunking

    private func confidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let value = run.transcriptionConfidence {
                total += Double(value)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    /// Merges the transcriber's phrase-sized results into chunks long enough to
    /// carry meaning for full-text search, but short enough that a hit still
    /// points at the right instant.
    private func chunk(_ results: [(CMTimeRange, String, Double?)]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentText: [String] = []
        var currentStart: Double?
        var currentEnd: Double = 0
        var confidences: [Double] = []

        func flush() {
            guard let start = currentStart, !currentText.isEmpty else { return }
            segments.append(TranscriptSegment(
                startSeconds: start,
                endSeconds: max(currentEnd, start),
                text: currentText.joined(separator: " "),
                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)))
            currentText.removeAll()
            currentStart = nil
            confidences.removeAll()
        }

        for (range, text, confidence) in results {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.end)
            guard start.isFinite else { continue }

            if currentStart == nil { currentStart = start }
            currentText.append(text)
            currentEnd = end.isFinite ? end : currentEnd
            if let confidence { confidences.append(confidence) }

            if currentEnd - (currentStart ?? currentEnd) >= options.chunkSeconds {
                flush()
            }
        }
        flush()
        return segments
    }
}

/// Hands the input buffer to `AVAudioConverter`'s pull callback exactly once.
/// The callback runs synchronously inside `convert(to:error:)`, but the compiler
/// can't prove that, so the buffer travels in a box.
private final class ConversionState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
