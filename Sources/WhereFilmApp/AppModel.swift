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
    var lastPlan: SearchPlan?
    var searchError: String?
    var precision: SearchPrecision = SearchPrecision.saved {
        didSet { precision.save() }
    }

    // Setup state.
    var modelInstalled = false
    var foundationModelStatus = ""

    private(set) var store: IndexStore?
    private var vectorIndex: VectorIndex?
    private var indexer: Indexer?
    private var indexerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
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
        guard let store else { return }
        do {
            try libraryAccess.remember(url)
            if !libraries.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                libraries.append(url)
            }
            libraryError = nil
        } catch {
            libraryError = "No pudimos conservar el acceso a esa carpeta: \(error.localizedDescription)"
        }
        Task(priority: .utility) {
            let scanner = LibraryScanner(store: store)
            do {
                _ = try await scanner.scan(root: url)
            } catch {
                await MainActor.run {
                    self.libraryError = "No pudimos revisar esa carpeta: \(error.localizedDescription)"
                }
            }
            await refresh()
        }
    }

    /// Re-walks every folder the person already added, once, at launch.
    ///
    /// Without this the app only ever sees the files that existed the moment a
    /// folder was first chosen — shoot something new, reopen WhereFilm, and it
    /// is invisible. Scanning is cheap and idempotent: known files are
    /// recognised by content and skipped, so this costs a directory walk.
    private func rescanKnownLibraries() {
        guard let store, !libraries.isEmpty else { return }
        let roots = libraries
        Task(priority: .background) {
            let scanner = LibraryScanner(store: store)
            for root in roots {
                // A folder can live on a drive that is simply unplugged today.
                // That is ordinary, not an error worth showing anyone.
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                _ = try? await scanner.scan(root: root)
            }
            await refresh()
        }
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

    func runSearch() async {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let text = query
        let variant = variant
        let vectorIndex = vectorIndex

        do {
            let plan = await QueryPlanner().plan(text)
            lastPlan = plan

            var options = SearchEngine.Options()
            options.limit = 30
            options.variant = variant
            options.weights.minimumVisualSimilarity = precision.minimumVisualSimilarity
            options.minimumConfidence = precision.minimumConfidence
            let engine = SearchEngine(store: store, options: options)

            try? await vectorIndex?.openForSearch()
            // Only publish results if the query hasn't moved on while we worked.
            var found = try await engine.search(plan: plan, vectorIndex: vectorIndex)
            // The on-device language model is an optional query enhancer, not a
            // single point of failure. If its decomposition is too narrow, retry
            // with the deterministic Spanish lexicon before telling someone the
            // library has no match.
            if found.isEmpty, plan.source == .foundationModel {
                let fallback = await QueryPlanner(useFoundationModel: false).plan(text)
                lastPlan = fallback
                found = try await engine.search(plan: fallback, vectorIndex: vectorIndex)
            }
            guard text == query else { return }
            results = found
        } catch {
            searchError = error.localizedDescription
            results = []
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
