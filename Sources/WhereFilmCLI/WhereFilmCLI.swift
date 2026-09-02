import Foundation
import ArgumentParser
import Speech
import WhereFilmCore
import WhereFilmML
import WhereFilmIndex
import WhereFilmSearch

// The CLI is not a side project. It exercises the entire engine without a single
// line of UI, which is how the pipeline gets measured on real hardware — the only
// way to know what Core ML and the Neural Engine actually do with your footage.

@main
struct WhereFilm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wherefilm",
        abstract: "Local semantic search for video and photos.",
        discussion: """
            Indexing is expensive; searching is nearly free. A 30 GB file is read \
            once, and after that every query only compares small precomputed vectors.
            """,
        version: "0.1.0",
        subcommands: [Scan.self, Index.self, Search.self, Status.self,
                      Volumes.self, Doctor.self, Rebuild.self, Tokenize.self,
                      BenchmarkFixture.self],
        defaultSubcommand: Status.self)
}

// MARK: - Shared

struct StoreOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the index database.")
    var database: String?

    func makeStore() throws -> IndexStore {
        try AppPaths.createDirectories()
        let url = database.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? AppPaths.database
        return try IndexStore(url: url)
    }
}

func makeVectorIndex(variant: MobileCLIPVariant) throws -> VectorIndex {
    try VectorIndex(modelID: variant.modelID, dimensions: variant.dimensions)
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Catalog a folder or drive in place. Originals are never moved or copied.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(help: "Folder or volume to scan.")
    var path: String

    @Flag(name: .long, help: "Don't queue transcription for files with audio.")
    var noTranscript = false

    @Flag(name: .long, help: "Scan and index in one go.")
    var index = false

    func run() async throws {
        let store = try storeOptions.makeStore()
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        var options = LibraryScanner.Options()
        options.enqueueTranscription = !noTranscript

        let scanner = LibraryScanner(store: store, options: options)
        print("Scanning \(root.path)…")

        let report = try await scanner.scan(root: root) { count, url in
            if count % 25 == 0 {
                FileHandle.standardError.write(
                    Data("  \(count) files… \(url.lastPathComponent)\r".utf8))
            }
        }

        print("""

            \(report.filesSeen) media files seen
            \(report.newAssets) new assets
            \(report.newLocations) new locations for assets already known
            \(report.rebound) already indexed
            \(report.renamed) renamed (search text refreshed)
            \(report.markedMissing) marked missing
            \(report.skipped) skipped (too small)
            """)
        for error in report.errors.prefix(10) { print("  ! \(error)") }
        if report.errors.count > 10 { print("  … and \(report.errors.count - 10) more") }

        if index {
            print("")
            try await Index.runIndexing(store: store, limit: .max, tasks: JobTask.allCases,
                                        variant: .s0, fullSpeed: true, quiet: false)
        }
    }
}

// MARK: - index

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Work through the job queue: keyframes, embeddings, OCR, transcripts.")

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .long, help: "Stop after this many jobs.")
    var limit: Int = .max

    @Option(name: .long, help: "Only run these tasks (metadata, visual, ocr, transcribe, strongHash).")
    var tasks: [String] = []

    @Option(name: .long, help: "MobileCLIP variant: s0, s1, s2, blt.")
    var model: String = "s0"

    @Flag(name: .long, help: "Ignore thermal, battery and foreground-editor throttling.")
    var fullSpeed = false

    @Flag(name: .long, help: "Skip on-screen text recognition. Useful for isolating where time goes.")
    var noOcr = false

    @Option(name: .long, help: "How many jobs to run at once. Defaults to what the governor allows.")
    var concurrency: Int?

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'. Try s0, s1, s2 or blt.")
        }
        let selected = tasks.isEmpty
            ? JobTask.allCases
            : tasks.compactMap { JobTask(rawValue: $0) }
        guard !selected.isEmpty else { throw ValidationError("No valid tasks given.") }

        try await Self.runIndexing(store: store, limit: limit, tasks: selected,
                                   variant: variant, fullSpeed: fullSpeed, quiet: false,
                                   recognizeText: !noOcr, concurrency: concurrency)
    }

    static func runIndexing(store: IndexStore, limit: Int, tasks: [JobTask],
                            variant: MobileCLIPVariant, fullSpeed: Bool, quiet: Bool,
                            recognizeText: Bool = true, concurrency: Int? = nil) async throws {
        let vectorIndex = try makeVectorIndex(variant: variant)

        var indexerOptions = Indexer.Options()
        indexerOptions.variant = variant
        indexerOptions.recognizeText = recognizeText

        var governorSettings = ResourceGovernor.Settings()
        governorSettings.mode = fullSpeed ? .fullSpeed : .smart

        let indexer = Indexer(store: store, vectorIndex: vectorIndex,
                              options: indexerOptions,
                              governor: ResourceGovernor(settings: governorSettings))

        let decision = ResourceGovernor(settings: governorSettings).decide()
        if !decision.isWorking {
            print("Indexer is throttled: \(decision.reason.label).")
            print("Use --full-speed to override, or close your editor.")
            return
        }

        if !quiet {
            await indexer.setEventHandler { event in
                switch event {
                case .started(_, let task, let name):
                    print("→ \(task.rawValue): \(name)")
                case .finished(_, let task, let detail):
                    print("  ✓ \(task.rawValue): \(detail)")
                case .skipped(_, let task, let reason):
                    print("  – \(task.rawValue) skipped: \(reason)")
                case .failed(_, let task, let error):
                    print("  ! \(task.rawValue) failed: \(error)")
                case .modelLoaded(let id):
                    print("  · loaded \(id)")
                case .modelReleased(let id):
                    print("  · released \(id) — memory returned to the system")
                case .throttled(let reason):
                    print("  · \(reason.label)")
                case .idle:
                    break
                }
            }
        }

        let start = Date()
        // The governor says what the machine may do; `--tasks` says what the
        // person asked this invocation to do. Both constraints must hold. The
        // previous code validated `--tasks` and then accidentally ignored it,
        // which made isolated OCR/transcription benchmarks run unrelated jobs.
        let allowed = decision.allowedTasks.filter(tasks.contains)
        guard !allowed.isEmpty else {
            print("The requested task types are currently throttled: \(decision.reason.label).")
            print("Use --full-speed to override, or connect the Mac to power.")
            return
        }
        let processed = await indexer.drain(allowedTasks: allowed, limit: limit,
                                            concurrency: concurrency)
        let elapsed = Date().timeIntervalSince(start)

        print("\nProcessed \(processed) jobs in \(String(format: "%.1f", elapsed))s.")
        let stats = try store.stats()
        print("\(stats.moments) moments · \(stats.embeddings) embeddings · \(stats.transcriptChunks) transcript chunks")
        if stats.pendingJobs > 0 { print("\(stats.pendingJobs) jobs still queued.") }
        if stats.failedJobs > 0 { print("\(stats.failedJobs) jobs failed — see `wherefilm status`.") }
    }
}

// MARK: - search

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find moments with a plain-language description.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(parsing: .remaining, help: "What you're looking for.")
    var query: [String]

    @Option(name: .shortAndLong, help: "How many results.")
    var limit: Int = 10

    @Option(name: .long, help: "MobileCLIP variant: s0, s1, s2, blt.")
    var model: String = "s0"

    @Flag(name: .long, help: "Show how the query was decomposed.")
    var explain = false

    @Flag(name: .long, help: "Skip the Apple on-device model even if it's available.")
    var noLLM = false

    @Option(name: .long, help: "Cosine similarity below which a visual hit is discarded.")
    var minVisual: Float?

    @Option(name: .long, help: "Cosine similarity treated as a perfect visual match.")
    var strongVisual: Float?

    @Option(name: .long, help: "How many candidates each channel retrieves before fusion.")
    var channelDepth: Int?

    @Option(name: .long, help: "Repeat the same query in-process and report p50/p95/p99 latency.")
    var benchmarkRuns = 1

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'.")
        }
        let text = query.joined(separator: " ")
        guard !text.isEmpty else { throw ValidationError("Say what you're looking for.") }
        guard benchmarkRuns > 0 else { throw ValidationError("--benchmark-runs must be greater than zero.") }

        let totalStarted = Date()
        let planner = QueryPlanner(useFoundationModel: !noLLM)
        let plan = await planner.plan(text)

        if explain {
            print("Query plan (\(plan.source.rawValue)):")
            print("  visual   : \(plan.visualPhrases.isEmpty ? "—" : plan.visualPhrases.joined(separator: " | "))")
            print("  spoken   : \(plan.spokenTerms.isEmpty ? "—" : plan.spokenTerms.joined(separator: ", "))")
            print("  literal  : \(plan.literalTerms.isEmpty ? "—" : plan.literalTerms.joined(separator: ", "))")
            print("")
        }

        let vectorIndex = try makeVectorIndex(variant: variant)
        try? await vectorIndex.openForSearch()

        var options = SearchEngine.Options()
        options.limit = limit
        options.variant = variant
        if let channelDepth { options.channelDepth = channelDepth }
        if let minVisual { options.weights.minimumVisualSimilarity = minVisual }
        if let strongVisual { options.weights.strongVisualSimilarity = strongVisual }

        let engine = SearchEngine(store: store, options: options)
        var results: [SearchResult] = []
        var firstUsefulSamples: [Double] = []
        var stableSamples: [Double] = []
        var searchTotalSamples: [Double] = []
        var lastTimings = SearchTimings()

        for _ in 0..<benchmarkRuns {
            let searchStarted = Date()
            var firstUsefulMilliseconds: Double?
            var stableMilliseconds = 0.0
            var lastUpdateTimings = SearchTimings()
            for try await update in engine.searchProgressively(plan: plan, vectorIndex: vectorIndex) {
                if firstUsefulMilliseconds == nil, !update.results.isEmpty {
                    firstUsefulMilliseconds = update.elapsedMilliseconds
                }
                results = update.results
                lastUpdateTimings = update.timings
                if update.isFinal { stableMilliseconds = update.elapsedMilliseconds }
            }
            lastTimings = lastUpdateTimings
            firstUsefulSamples.append(firstUsefulMilliseconds ?? stableMilliseconds)
            stableSamples.append(stableMilliseconds)
            searchTotalSamples.append(Date().timeIntervalSince(searchStarted) * 1_000)
        }
        let totalMilliseconds = Date().timeIntervalSince(totalStarted) * 1_000

        if benchmarkRuns > 1 {
            let warmFirstUseful = Array(firstUsefulSamples.dropFirst())
            let warmStable = Array(stableSamples.dropFirst())
            let warmSearchTotal = Array(searchTotalSamples.dropFirst())
            print("Benchmark (1 cold + \(benchmarkRuns - 1) warm in-process runs)")
            print("  cold          first useful \(format(firstUsefulSamples[0])) ms · stable \(format(stableSamples[0])) ms · total \(format(searchTotalSamples[0])) ms")
            printLatency("warm useful", warmFirstUseful)
            printLatency("warm stable", warmStable)
            printLatency("warm total", warmSearchTotal)
            print("  stages       \(lastTimings.summary)")
            print("")
        }

        let firstUsefulMilliseconds = firstUsefulSamples.last ?? 0
        let stableMilliseconds = stableSamples.last ?? 0

        guard !results.isEmpty else {
            print("No moments found.")
            print("(stable \(String(format: "%.1f", stableMilliseconds)) ms · total \(String(format: "%.1f", totalMilliseconds)) ms)")
            return
        }

        print("Found \(results.count) moment\(results.count == 1 ? "" : "s") · first useful \(String(format: "%.1f", firstUsefulMilliseconds)) ms · stable \(String(format: "%.1f", stableMilliseconds)) ms · command total \(String(format: "%.1f", totalMilliseconds)) ms\n")
        for (rank, result) in results.enumerated() {
            let percent = Int((result.score * 100).rounded())
            print("\(rank + 1). \(result.displayName)  \(result.timeRange)   \(percent)%")
            for evidence in result.evidence.prefix(3) {
                print("     ✓ \(evidence.label)")
            }
            if let location = result.bestLocation {
                let marker = location.availability == .online ? " " : "⚠"
                print("     \(marker) \(location.summary) — \(location.relativePath)")
            }
            if let preview = result.previewPath {
                print("       preview: \(preview.path)")
            }
            print("")
        }
    }

    private func printLatency(_ label: String, _ samples: [Double]) {
        print("  \(label.padding(toLength: 13, withPad: " ", startingAt: 0)) p50 \(format(percentile(0.50, samples))) ms · p95 \(format(percentile(0.95, samples))) ms · p99 \(format(percentile(0.99, samples))) ms")
    }

    private func percentile(_ fraction: Double, _ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * (rank - Double(lower)))
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What the index knows right now.")

    @OptionGroup var storeOptions: StoreOptions

    func run() async throws {
        let store = try storeOptions.makeStore()
        let stats = try store.stats()
        let governor = ResourceGovernor()
        let decision = governor.decide()

        print("""
            WhereFilm
            ─────────────────────────────────────────
            \(stats.assets) files discovered · \(stats.searchableAssets) searchable now
            \(stats.visuallyUnderstoodAssets) visually understood · \(stats.transcribedAssets) transcribed
            \(stats.ocrEnrichedAssets) with on-screen text · \(stats.enrichingAssets) being enriched
            \(stats.moments) moments · \(stats.embeddings) embeddings
            \(stats.transcriptChunks) transcript chunks
            \(stats.volumesOnline) drives online · \(stats.volumesOffline) offline
            \(stats.missingLocations) originals missing (index preserved)
            \(stats.pendingJobs) files pending · \(stats.failedJobs) failed

            Indexer  : \(decision.reason.label)
            Thermal  : \(governor.thermalStateDescription)
            Power    : \(governor.isOnACPower() ? "plugged in" : "on battery")
            Database : \(AppPaths.database.path)
            """)
    }
}

// MARK: - volumes

struct Volumes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drives this index knows about, and whether they're plugged in.")

    @OptionGroup var storeOptions: StoreOptions

    func run() async throws {
        let store = try storeOptions.makeStore()
        try LibraryScanner(store: store).syncVolumes()

        let volumes = try store.volumes()
        guard !volumes.isEmpty else {
            print("No volumes recorded yet. Run `wherefilm scan <path>`.")
            return
        }
        for volume in volumes.sorted(by: { $0.name < $1.name }) {
            let state = volume.isOnline ? "online " : "offline"
            print("\(state)  \(volume.name)")
            print("         uuid \(volume.volumeUUID)")
            if let fsType = volume.fsType { print("         \(fsType)") }
        }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that every on-device capability the app relies on is actually there.")

    func run() async throws {
        print("WhereFilm doctor\n────────────────")

        print("\nVector engine")
        print("  USearch \(VectorEngineInfo.version)  [\(VectorEngineInfo.acceleration)]")

        print("\nVisual model (\(AppPaths.models.path))")
        for variant in MobileCLIPVariant.allCases {
            let image = AppPaths.models.appendingPathComponent("\(variant.imageModelName).mlpackage")
            let imageCompiled = AppPaths.models.appendingPathComponent("\(variant.imageModelName).mlmodelc")
            let installed = FileManager.default.fileExists(atPath: image.path)
                || FileManager.default.fileExists(atPath: imageCompiled.path)
            print("  \(installed ? "✓" : "·") mobileclip-\(variant.rawValue) — \(variant.summary)")
        }
        let tokenizerReady = FileManager.default.fileExists(
            atPath: AppPaths.models.appendingPathComponent("clip-vocab.json").path)
        print("  \(tokenizerReady ? "✓" : "·") CLIP tokenizer assets")
        if !tokenizerReady {
            print("    → run Scripts/fetch-models.sh")
        }

        print("\nSpeech (system-managed, adds nothing to the app bundle)")
        print("  SpeechTranscriber available: \(SpeechTranscriber.isAvailable ? "yes" : "no")")
        let installed = await Transcriber.installedLocales()
        let supported = await Transcriber.supportedLocales()
        print("  \(supported.count) locales supported, \(installed.count) installed")
        for locale in installed.prefix(8) {
            print("    ✓ \(locale.identifier)")
        }
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            print("  your locale (\(current.identifier)) maps to \(match.identifier)")
        } else {
            print("  ⚠ your locale (\(current.identifier)) is not supported for transcription")
        }

        print("\nQuery understanding")
        print("  Apple Foundation Model: \(QueryPlanner.foundationModelStatus)")
        print("  (optional — the built-in lexicon covers Spanish queries without it)")

        print("\nVector index")
        for variant in MobileCLIPVariant.allCases {
            let url = AppPaths.vectorIndex(for: variant.modelID)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? Int64) ?? 0
            // The number the search path actually consults. A graph that is on
            // disk but reports zero vectors is the difference between a search
            // that answers in milliseconds and one that scans every vector in
            // SQLite, so it is worth being able to see it.
            let index = try? VectorIndex(modelID: variant.modelID,
                                         dimensions: variant.dimensions)
            try? await index?.openForSearch()
            let count = await index?.count ?? 0
            print("  \(variant.modelID): \(count) vectors · \((bytes / 1_048_576)) MB on disk")
            if count == 0 {
                print("    ⚠ the graph is present but reports no vectors — search will fall back")
                print("      to an exhaustive scan. Run `wherefilm rebuild-index`.")
            }
        }

        print("\nStorage")
        print("  database : \(AppPaths.database.path)")
        print("  vectors  : \(AppPaths.vectorIndexes.path)")
        print("  previews : \(AppPaths.previews.path)")
    }
}

// MARK: - rebuild

struct Rebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-index",
        abstract: "Rebuild the ANN index from SQLite. Safe: the vectors live in the database.")

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .long, help: "MobileCLIP variant.")
    var model: String = "s0"

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let variant = MobileCLIPVariant(rawValue: model) else {
            throw ValidationError("Unknown model '\(model)'.")
        }
        let total = try store.embeddingCount(modelID: variant.modelID)
        guard total > 0 else {
            print("No embeddings stored for \(variant.modelID).")
            return
        }

        print("Rebuilding \(variant.modelID) from \(total) stored vectors…")
        let vectorIndex = try makeVectorIndex(variant: variant)
        let start = Date()
        try await vectorIndex.rebuild(from: store) { done in
            FileHandle.standardError.write(Data("  \(done)/\(total)\r".utf8))
        }
        print("\nDone in \(String(format: "%.1f", Date().timeIntervalSince(start)))s.")
    }
}

// MARK: - tokenize

struct Tokenize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how text is tokenized for the CLIP text encoder.",
        discussion: """
            Useful for understanding recall differences between languages: \
            "man" is one token, "hombre" is two.
            """)

    @Argument(parsing: .remaining)
    var text: [String]

    func run() async throws {
        let tokenizer = try CLIPTokenizer(directory: AppPaths.models)
        let phrase = text.joined(separator: " ")
        let ids = tokenizer.tokenIDs(phrase)
        let full = tokenizer.encode(phrase)
        print("text   : \(phrase)")
        print("tokens : \(ids.count) (\(ids.map(String.init).joined(separator: ", ")))")
        print("padded : \(full.prefix(ids.count + 2).map(String.init).joined(separator: ", ")) … [\(full.count)]")
    }
}
