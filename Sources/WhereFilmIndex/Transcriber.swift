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
    case inputTerminated

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "The file has no audio track."
        case .localeUnsupported(let id): "SpeechTranscriber does not support the locale \(id)."
        case .modelUnavailable: "The on-device speech model is not installed and could not be downloaded."
        case .audioFormatUnavailable: "Could not negotiate an audio format with SpeechAnalyzer."
        case .inputTerminated: "SpeechAnalyzer stopped accepting audio before the file ended."
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
        /// A small, bounded amount of decoded PCM may wait for SpeechAnalyzer.
        /// Eight buffers keep both sides busy without allowing a multi-hour
        /// recording to materialise its entire audio track in memory.
        public var audioBufferCapacity = 8

        public init(locale: Locale = Locale.current) {
            self.locale = locale
        }
    }

    public var options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Which speech engine this machine can actually run.
    ///
    /// `SpeechTranscriber` is built around the neural engine, and macOS 26 is the
    /// last release that runs on Intel Macs — which have none. Apple's own answer
    /// to that is `DictationTranscriber`, documented as the fallback for devices
    /// and locales `SpeechTranscriber` does not cover, and it supports the same
    /// `audioTimeRange` attribute, which is the only part this product cannot
    /// live without: a transcript with no timestamps cannot answer "jump to
    /// 14:16".
    ///
    /// So the chain is: the good engine, then the available one, then nothing —
    /// and "nothing" is reported honestly rather than left as an empty transcript
    /// nobody can explain.
    public enum Engine: Sendable, Equatable {
        case speechTranscriber(Locale)
        case dictation(Locale)

        public var name: String {
            switch self {
            case .speechTranscriber: "SpeechTranscriber"
            case .dictation: "DictationTranscriber"
            }
        }

        public var locale: Locale {
            switch self {
            case .speechTranscriber(let locale), .dictation(let locale): locale
            }
        }

        /// Stored with every chunk, so a library transcribed by the weaker engine
        /// can be found and redone later — the same rule `modelID` follows for
        /// embeddings. Being able to *improve* an index without rebuilding it is
        /// the difference between a fallback and a dead end.
        public var identifier: String {
            "\(name.lowercased())-\(locale.identifier)"
        }
    }

    /// Locales the system can transcribe, whether or not the assets are
    /// downloaded yet. Always ask at runtime rather than hardcoding a list.
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public static func dictationLocales() async -> [Locale] {
        await DictationTranscriber.supportedLocales
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Picks the best engine this Mac can run for a locale, or nil when neither
    /// can.
    public static func engine(for locale: Locale) async -> Engine? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speechTranscriber(supported)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(supported)
        }
        return nil
    }

    /// One line for `doctor`, so "why is nothing being transcribed?" has an
    /// answer that does not require a debugger.
    public static func engineDescription(for locale: Locale) async -> String {
        guard let engine = await engine(for: locale) else {
            return "no speech engine supports \(locale.identifier) on this Mac"
        }
        switch engine {
        case .speechTranscriber(let supported):
            return "SpeechTranscriber · \(supported.identifier)"
        case .dictation(let supported):
            return "DictationTranscriber · \(supported.identifier) "
                + "— SpeechTranscriber is unavailable on this Mac"
        }
    }

    public func transcribe(url: URL) async throws -> [TranscriptSegment] {
        guard let engine = await Self.engine(for: options.locale) else {
            throw TranscriptionError.localeUnsupported(options.locale.identifier)
        }
        switch engine {
        case .speechTranscriber(let locale):
            return try await transcribeWithSpeechTranscriber(locale: locale, url: url)
        case .dictation(let locale):
            return try await transcribeWithDictation(locale: locale, url: url)
        }
    }

    /// The engine that will actually be used for this file, without running it.
    public func resolvedEngine() async -> Engine? {
        await Self.engine(for: options.locale)
    }

    private func transcribeWithSpeechTranscriber(locale: Locale,
                                                 url: URL) async throws -> [TranscriptSegment] {
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

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, options.audioBufferCapacity)))
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: options.priority, modelRetention: .whileInUse))

        // Collect results while the audio is still being pushed in.
        let collector = Task {
            var collected: [(CMTimeRange, String, Double?)] = []
            for try await result in transcriber.results where result.isFinal {
                // A final result may span roughly a minute, but the attributed
                // string carries an audio range on its smaller runs (usually a
                // word or phrase). Keeping only `result.range` made every search
                // hit jump to the start of that whole minute. Preserve the fine
                // timing now; `chunk` will merge it back into searchable blocks
                // around the requested 12 seconds.
                var appendedTimedRun = false
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append((range, text, run.transcriptionConfidence))
                    appendedTimedRun = true
                }
                if !appendedTimedRun {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append((result.range, text, confidence(of: result.text)))
                }
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

    /// The same pipeline, driven by the engine a Mac without a neural engine
    /// actually has.
    ///
    /// Everything below the module — pulling PCM out of the container, the
    /// bounded eight-buffer queue, the timestamp counter, the chunking — is
    /// shared, because none of it was ever specific to which recogniser was
    /// listening. What differs is one type and one attribute scope, which is
    /// exactly how much of this file should have to know about the difference.
    private func transcribeWithDictation(locale: Locale,
                                         url: URL) async throws -> [TranscriptSegment] {
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        try await ensureModelInstalled(for: transcriber, locale: locale)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatUnavailable
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, options.audioBufferCapacity)))
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: options.priority, modelRetention: .whileInUse))

        let collector = Task {
            var collected: [(CMTimeRange, String, Double?)] = []
            for try await result in transcriber.results {
                var appendedTimedRun = false
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append((range, text, run.transcriptionConfidence))
                    appendedTimedRun = true
                }
                if !appendedTimedRun {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append((result.range, text, confidence(of: result.text)))
                }
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

    private func ensureModelInstalled(for transcriber: any SpeechModule, locale: Locale) async throws {
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

            let input = AnalyzerInput(
                buffer: outputBuffer,
                bufferStartTime: CMTime(value: framePosition, timescale: timescale))
            try await yieldWithBackpressure(input, into: continuation)
            framePosition += Int64(outputBuffer.frameLength)
        }

        if reader.status == .failed, let error = reader.error { throw error }
    }

    /// `AsyncStream` is unbounded by default. AVAssetReader can decode PCM much
    /// faster than speech recognition consumes it, so a multi-hour video used
    /// to queue an unbounded number of AVAudioPCMBuffers. With a bounded stream,
    /// `.dropped` means "the queue is full"; retrying after a short suspension
    /// gives us lossless backpressure rather than dropped words or runaway RAM.
    private func yieldWithBackpressure(
        _ input: AnalyzerInput,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(input) {
            case .enqueued:
                return
            case .dropped:
                try await Task.sleep(for: .milliseconds(2))
            case .terminated:
                throw TranscriptionError.inputTerminated
            @unknown default:
                throw TranscriptionError.inputTerminated
            }
        }
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
