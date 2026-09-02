import Foundation
import Observation
import SwiftUI
import AppKit
import ServiceManagement
import WhereFilmCore
import WhereFilmML
import WhereFilmIndex
import WhereFilmSearch

/// The one place the UI talks to the engine.
///
/// It holds the store, the vector index and the background indexer, and keeps a
/// snapshot of the state the menu bar needs. Everything expensive lives behind
/// an actor; this object only ever holds numbers and strings.
@MainActor
@Observable
final class AppModel {
    // Indexer state, as the menu bar shows it.
    var mode: IndexerMode = .smart {
        didSet { applyGovernorSettings() }
    }
    var pausedUntil: Date? {
        didSet { applyGovernorSettings() }
    }
    var throttleReason: ThrottleReason = .none
    var currentActivity: String?

    // Library state.
    var stats = IndexStore.Stats()
    var volumes: [Volume] = []
    var libraries: [URL] = []
    var libraryError: String?

    // Search state.
    var query = ""
    var results: [SearchResult] = []
    var isSearching = false
    var isSearchTakingLong = false
    var searchPhase: SearchPhase?
    var firstUsefulResultMilliseconds: Double?
    var stableResultMilliseconds: Double?
    var lastPlan: SearchPlan?
    var searchError: String?
    var precision: SearchPrecision = SearchPrecision.saved {
        didSet { precision.save() }
    }

    // Setup state.
    var modelInstalled = false
    var foundationModelStatus = ""

    /// Whether to drop back to a menu-bar-only agent with no Dock icon.
    ///
    /// Off by default. WhereFilm shipped as an `LSUIElement` agent and the cost
    /// was that it never appeared in Spotlight, Launchpad, the Dock or Cmd-Tab —
    /// it was installed but unfindable. Being a normal application is the
    /// default; hiding is a preference for people who want it, not a shape
    /// forced on everyone.
    var hidesDockIcon: Bool = UserDefaults.standard.bool(forKey: "hidesDockIcon") {
        didSet {
            UserDefaults.standard.set(hidesDockIcon, forKey: "hidesDockIcon")
            NSApp.setActivationPolicy(hidesDockIcon ? .accessory : .regular)
            // Coming back from .accessory leaves the app un-frontmost; without
            // this the window is there but behind everything.
            if !hidesDockIcon { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    private(set) var store: IndexStore?
    private var vectorIndex: VectorIndex?
    private var indexer: Indexer?
    private var indexerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var rescanDebounceTask: Task<Void, Never>?
    private var libraryScanTask: Task<Void, Never>?
    private var libraryScanWorkerTask: Task<[String], Never>?
    private var libraryScanNeedsRun = false
    private var searchTask: Task<Void, Never>?
    private var slowSearchIndicatorTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var libraryMonitor: LibraryChangeMonitor?
    private let libraryAccess = LibraryAccess()
    let variant = MobileCLIPVariant.s0

    var startupError: String?
    private var hasStarted = false

    /// One instance for the whole process: the menu bar, the search window and
    /// the AppDelegate all talk to the same engine.
    static let shared = AppModel()

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            try AppPaths.createDirectories()
            let store = try IndexStore(url: AppPaths.database)
            // Upgrade only the derived channels whose algorithms changed. The
            // originals, moments, embeddings and previews remain usable while
            // these low-priority backfills run in the normal queue.
            try store.prepareOCRBackfill(version: "vision-accurate-1024-v1")
            try store.prepareTranscriptionBackfill(version: "speech-timed-runs-v1")
            let vectorIndex = try VectorIndex(modelID: variant.modelID,
                                              dimensions: variant.dimensions)
            self.store = store
            self.vectorIndex = vectorIndex

            var options = Indexer.Options()
            options.variant = variant
            let environment = ProcessInfo.processInfo.environment
            // A release verification must exercise the complete pipeline even
            // when the MacBook happens to be unplugged. This is private to the
            // QA process; normal launches still default to battery-aware Smart.
            if environment["WHEREFILM_QA_REPORT"] != nil {
                mode = .fullSpeed
            }
            let indexer = Indexer(
                store: store,
                vectorIndex: vectorIndex,
                options: options,
                governor: ResourceGovernor(settings: governorSettings)
            )
            self.indexer = indexer

            modelInstalled = FileManager.default.fileExists(
                atPath: AppPaths.models
                    .appendingPathComponent("\(variant.imageModelName).mlmodelc").path)
            foundationModelStatus = QueryPlanner.foundationModelStatus
            libraries = libraryAccess.restore()
            restartLibraryMonitor()

            observeIndexer(indexer)
            startIndexer()
            startRefreshLoop()
            rescanKnownLibraries()

            // When running normally on a user's Mac and no libraries have been
            // explicitly chosen yet, automatically discover and index standard
            // media directories (Pictures, Movies, Downloads, Desktop, Documents).
            if libraries.isEmpty,
               environment["WHEREFILM_QA_REPORT"] == nil,
               environment["WHEREFILM_QA_LIBRARY"] == nil {
                scanAllMediaLocations()
            }

            // Private QA hooks: let the release bundle be exercised against an
            // isolated fixture without automating keyboard input or clicking
            // through an open-file dialog. Inert in normal launches, because
            // both environment variables are absent.
            if let path = environment["WHEREFILM_QA_LIBRARY"], !path.isEmpty {
                addLibrary(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
            if let demoQuery = environment["WHEREFILM_DEMO_QUERY"], !demoQuery.isEmpty {
                query = demoQuery
                Task { await runSearch() }
            }
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func observeIndexer(_ indexer: Indexer) {
        Task {
            await indexer.setEventHandler { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
        }
    }

    private func apply(_ event: IndexerEvent) {
        switch event {
        case .started(_, let task, let name):
            currentActivity = "\(task.rawValue): \(name)"
        case .finished, .skipped:
            currentActivity = nil
        case .failed(_, let task, let error):
            currentActivity = "\(task.rawValue) failed: \(error)"
        case .throttled(let reason):
            throttleReason = reason
            currentActivity = nil
        case .idle:
            throttleReason = .none
            currentActivity = nil
        case .modelLoaded, .modelReleased:
            break
        }
    }

    private func startIndexer() {
        guard let indexer else { return }
        indexerTask?.cancel()
        // The whole indexing pipeline runs at background priority. It is
        // maintenance work and must never outrank whatever the person is
        // actually doing.
        indexerTask = Task(priority: .background) {
            await indexer.run()
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard let store else { return }
        stats = (try? store.stats()) ?? stats
        volumes = (try? store.volumes()) ?? volumes
        let decision = ResourceGovernor(settings: governorSettings).decide()
        // A restricted decision can still allow cheap metadata work. Reporting
        // that as simply "working" hid the fact that visual/transcription jobs
        // were intentionally deferred on battery.
        throttleReason = decision.reason
        if decision.scanConcurrency > 0, libraryScanNeedsRun {
            // Also wakes a timed pause or thermal backoff without requiring a
            // second user action.
            startQueuedLibraryScan()
        }
    }

    // MARK: - Governor

    private var governorSettings: ResourceGovernor.Settings {
        var settings = ResourceGovernor.Settings()
        settings.mode = mode
        settings.pausedUntil = pausedUntil
        return settings
    }

    private func applyGovernorSettings() {
        guard let indexer else { return }
        let settings = governorSettings
        Task { await indexer.setGovernorSettings(settings) }
        let paused = mode == .paused || (pausedUntil ?? .distantPast) > Date()
        if paused {
            // A large directory walk can outlive a menu-bar pause. Cancel the
            // actual detached worker, not only the MainActor watcher awaiting it.
            libraryScanNeedsRun = true
            libraryScanWorkerTask?.cancel()
        } else if libraryScanNeedsRun {
            startQueuedLibraryScan()
        }
    }

    func pause(for duration: TimeInterval?) {
        if let duration {
            pausedUntil = Date().addingTimeInterval(duration)
            mode = .smart
        } else {
            pausedUntil = nil
            mode = .paused
        }
    }

    func resume() {
        pausedUntil = nil
        mode = .smart
    }

    var pauseRemaining: String? {
        guard let pausedUntil, pausedUntil > Date() else { return nil }
        let remaining = Int(pausedUntil.timeIntervalSinceNow)
        if remaining >= 3600 {
            return "\(remaining / 3600) h \((remaining % 3600) / 60) min"
        }
        return "\(max(1, remaining / 60)) min"
    }

    // MARK: - Library

    func addLibrary(_ url: URL) {
        guard store != nil else { return }
        do {
            try libraryAccess.remember(url)
            if !libraries.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                libraries.append(url)
            }
            restartLibraryMonitor()
            libraryError = nil
        } catch {
            libraryError = "No pudimos conservar el acceso a esa carpeta: \(error.localizedDescription)"
        }
        queueLibraryScan()
    }

    /// Re-walks every folder the person already added, once, at launch.
    ///
    /// Without this the app only ever sees the files that existed the moment a
    /// folder was first chosen — shoot something new, reopen WhereFilm, and it
    /// is invisible. Scanning is cheap and idempotent: an unchanged path is
    /// recognised by size + modification date without opening the media, so
    /// this costs a directory walk and small database lookups.
    private func rescanKnownLibraries() {
        queueLibraryScan()
    }

    /// Coalesces Finder bursts and several newly added folders into one scan
    /// coordinator. Roots on one volume are walked serially; roots on separate
    /// disks may run together only when Smart mode says the machine is free.
    private func queueLibraryScan() {
        libraryScanNeedsRun = true
        startQueuedLibraryScan()
    }

    private func startQueuedLibraryScan() {
        guard libraryScanTask == nil, libraryScanNeedsRun, let store else { return }

        let roots = deduplicatedLibraryRoots()
        guard !roots.isEmpty else {
            libraryScanNeedsRun = false
            return
        }

        let settings = governorSettings
        let initialDecision = ResourceGovernor(settings: settings).decide()
        // A user pause and critical thermal state must also stop discovery work;
        // the request stays queued and is retried when settings change.
        guard initialDecision.scanConcurrency > 0 else { return }
        libraryScanNeedsRun = false

        let worker = Task.detached(priority: .background) { () -> [String] in
            let governor = ResourceGovernor(settings: settings)
            let registry = VolumeRegistry()
            var groups: [[URL]] = []
            var groupForKey: [String: Int] = [:]

            // Never make two enumerators seek against the same disk. Separate
            // volumes are the safe unit of parallelism for a media library.
            for root in roots {
                let key = registry.resolve(root)?.volume.uuid ?? root.standardizedFileURL.path
                if let index = groupForKey[key] {
                    groups[index].append(root)
                } else {
                    groupForKey[key] = groups.count
                    groups.append([root])
                }
            }

            var errors: [String] = []
            let width = max(1, initialDecision.scanConcurrency)
            var offset = 0
            while offset < groups.count, !Task.isCancelled {
                let end = min(groups.count, offset + width)
                let batch = Array(groups[offset..<end])
                let batchErrors = await withTaskGroup(of: [String].self,
                                                       returning: [[String]].self) { group in
                    for roots in batch {
                        group.addTask {
                            let scanner = LibraryScanner(
                                store: store,
                                governor: governor)
                            var localErrors: [String] = []
                            for root in roots {
                                guard !Task.isCancelled else { break }
                                // An unplugged drive is ordinary, not an error
                                // worth showing in the menu bar.
                                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                                do {
                                    _ = try await scanner.scan(root: root)
                                } catch {
                                    localErrors.append("\(root.path): \(error.localizedDescription)")
                                }
                            }
                            return localErrors
                        }
                    }
                    var collected: [[String]] = []
                    for await local in group { collected.append(local) }
                    return collected
                }
                errors.append(contentsOf: batchErrors.flatMap { $0 })
                offset = end
            }
            return errors
        }
        libraryScanWorkerTask = worker

        libraryScanTask = Task { [weak self] in
            let errors = await worker.value
            guard let self else { return }
            self.libraryScanTask = nil
            self.libraryScanWorkerTask = nil
            if let first = errors.first {
                self.libraryError = "No pudimos revisar una carpeta: \(first)"
            }
            await self.refresh()
            if self.libraryScanNeedsRun { self.startQueuedLibraryScan() }
        }
    }

    /// Removes nested roots such as `~/Movies` plus `~/Movies/Projects`, which
    /// otherwise cause every media file below the child to be probed twice.
    private func deduplicatedLibraryRoots() -> [URL] {
        let sorted = libraries.map(\.standardizedFileURL).sorted {
            $0.path.count < $1.path.count
        }
        var kept: [URL] = []
        for candidate in sorted {
            let path = candidate.path
            let covered = kept.contains { root in
                path == root.path || path.hasPrefix(root.path.hasSuffix("/")
                                                     ? root.path
                                                     : root.path + "/")
            }
            if !covered { kept.append(candidate) }
        }
        return kept
    }

    /// FSEvents may report a burst for one Finder operation. Wait briefly, then
    /// do one authoritative incremental scan. Renaming a file becomes visible
    /// without restarting the app or teaching the catalog to trust event paths.
    private func scheduleLibraryRescan() {
        rescanDebounceTask?.cancel()
        rescanDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.25))
            guard !Task.isCancelled else { return }
            self?.rescanKnownLibraries()
        }
    }

    private func restartLibraryMonitor() {
        libraryMonitor?.stop()
        guard !libraries.isEmpty else {
            libraryMonitor = nil
            return
        }
        let monitor = LibraryChangeMonitor(paths: libraries) { [weak self] in
            Task { @MainActor in self?.scheduleLibraryRescan() }
        }
        libraryMonitor = monitor
        _ = monitor.start()
    }

    /// Discovers and indexes standard user media directories on macOS
    /// (~/Pictures, ~/Movies, ~/Downloads, ~/Desktop, ~/Documents) and mounted volumes.
    func scanAllMediaLocations() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let mediaFolders: [URL] = [
            home.appendingPathComponent("Pictures", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
        ]

        for folder in mediaFolders {
            if fm.fileExists(atPath: folder.path) {
                addLibrary(folder)
            }
        }

        // Also index external drives and connected storage
        let mounted = VolumeRegistry().mountedVolumes()
        for vol in mounted {
            if vol.mountURL.path != "/" {
                addLibrary(vol.mountURL)
            }
        }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Añadir"
        panel.message = "Elige una carpeta o un disco. WhereFilm no mueve ni duplica tus originales."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addLibrary(url)
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            libraryError = nil
        } catch {
            libraryError = "No pudimos cambiar el inicio automático: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    /// Called as the query changes. Ninety milliseconds is long enough to avoid
    /// completing `g` after the person has typed `guy`, but short enough to feel
    /// like direct manipulation rather than a submit form.
    func scheduleSearch() {
        _ = replaceSearch(after: .milliseconds(90))
    }

    func runSearch() async {
        let task = replaceSearch(after: nil)
        await task?.value
    }

    @discardableResult
    private func replaceSearch(after delay: Duration?) -> Task<Void, Never>? {
        searchTask?.cancel()
        slowSearchIndicatorTask?.cancel()
        isSearchTakingLong = false
        searchGeneration += 1
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            results = []
            lastPlan = nil
            searchPhase = nil
            isSearching = false
            return nil
        }

        // One-character prefixes create a huge, low-value FTS fanout and are
        // almost always an intermediate keystroke. Keep the previous results
        // in place until there is enough intent to search.
        guard text.count >= 2 else {
            isSearching = false
            return nil
        }

        let task = Task { [weak self] in
            if let delay {
                do { try await Task.sleep(for: delay) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(text: text, generation: generation)
        }
        searchTask = task
        return task
    }

    private func performSearch(text: String, generation: Int) async {
        guard let store, generation == searchGeneration else { return }
        isSearching = true
        searchError = nil
        searchPhase = nil
        firstUsefulResultMilliseconds = nil
        stableResultMilliseconds = nil
        let variant = variant
        let vectorIndex = vectorIndex
        let activeIndexer = indexer

        slowSearchIndicatorTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, self.searchGeneration == generation,
                  self.isSearching, self.results.isEmpty else { return }
            self.isSearchTakingLong = true
        }

        await activeIndexer?.beginInteractiveSearch()

        do {
            // The deterministic planner is the interactive route. Apple's local
            // Foundation Model measured 4.76 s end-to-end on this machine; it
            // cannot gate first feedback, and the product does not require it.
            let plan = await QueryPlanner(useFoundationModel: false).plan(text)
            try Task.checkCancellation()
            guard generation == searchGeneration, text == query.trimmingCharacters(in: .whitespacesAndNewlines)
            else { throw CancellationError() }
            lastPlan = plan

            var options = SearchEngine.Options()
            options.limit = 30
            options.variant = variant
            options.weights.minimumVisualSimilarity = precision.minimumVisualSimilarity
            options.minimumConfidence = precision.minimumConfidence
            let engine = SearchEngine(store: store, options: options)

            // Safe whether the shared index is a read-only mmap or the writable
            // graph currently receiving background additions.
            try? await vectorIndex?.openForSearch()
            for try await update in engine.searchProgressively(plan: plan, vectorIndex: vectorIndex) {
                try Task.checkCancellation()
                guard generation == searchGeneration,
                      text == query.trimmingCharacters(in: .whitespacesAndNewlines)
                else { throw CancellationError() }

                searchPhase = update.phase
                if firstUsefulResultMilliseconds == nil, !update.results.isEmpty {
                    firstUsefulResultMilliseconds = update.elapsedMilliseconds
                }
                if update.isFinal { stableResultMilliseconds = update.elapsedMilliseconds }

                // Do not flash an empty fast snapshot over useful results from
                // the previous prefix. The final empty snapshot is authoritative.
                if !update.results.isEmpty || update.isFinal {
                    results = update.results
                }
                if !update.results.isEmpty {
                    slowSearchIndicatorTask?.cancel()
                    isSearchTakingLong = false
                }
            }
        } catch is CancellationError {
            // A newer query owns the UI now. Cancellation is ordinary control
            // flow, not an error worth flashing at the person typing.
        } catch {
            if generation == searchGeneration {
                searchError = error.localizedDescription
            }
        }

        await activeIndexer?.endInteractiveSearch()
        if generation == searchGeneration {
            slowSearchIndicatorTask?.cancel()
            isSearchTakingLong = false
            isSearching = false
        }
    }
}

enum SearchPrecision: String, CaseIterable, Identifiable {
    case precise
    case balanced
    case broad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .precise: "Precisa"
        case .balanced: "Equilibrada"
        case .broad: "Amplia"
        }
    }

    var explanation: String {
        switch self {
        case .precise: "Solo coincidencias claras"
        case .balanced: "La mejor opción para empezar"
        case .broad: "Más ideas, aunque sean aproximadas"
        }
    }

    var minimumVisualSimilarity: Float {
        switch self {
        case .precise: 0.16
        case .balanced: 0.14
        case .broad: 0.12
        }
    }

    /// The lowest confidence worth putting on screen, on the same scale the
    /// cards show as a percentage. Measured against the real library: a correct
    /// match lands at 26–45%, and the tail below 10% is noise that makes the
    /// good answers above it look less trustworthy than they are.
    var minimumConfidence: Double {
        switch self {
        case .precise: 0.22
        case .balanced: 0.10
        case .broad: 0.03
        }
    }

    static var saved: SearchPrecision {
        let value = UserDefaults.standard.string(forKey: "wherefilm.searchPrecision")
        return value.flatMap(SearchPrecision.init(rawValue:)) ?? .balanced
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "wherefilm.searchPrecision")
    }
}
