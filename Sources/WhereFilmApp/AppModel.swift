import Foundation
import Observation
import SwiftUI
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

    // Search state.
    var query = ""
    var results: [SearchResult] = []
    var isSearching = false
    var lastPlan: SearchPlan?
    var searchError: String?

    // Setup state.
    var modelInstalled = false
    var foundationModelStatus = ""

    private(set) var store: IndexStore?
    private var vectorIndex: VectorIndex?
    private var indexer: Indexer?
    private var indexerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
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
            let indexer = Indexer(store: store, vectorIndex: vectorIndex, options: options)
            self.indexer = indexer

            modelInstalled = FileManager.default.fileExists(
                atPath: AppPaths.models
                    .appendingPathComponent("\(variant.imageModelName).mlmodelc").path)
            foundationModelStatus = QueryPlanner.foundationModelStatus

            observeIndexer(indexer)
            startIndexer()
            startRefreshLoop()
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
        if !decision.isWorking || throttleReason != .none {
            throttleReason = decision.reason
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
            return "\(remaining / 3600)h \((remaining % 3600) / 60)m left"
        }
        return "\(max(1, remaining / 60))m left"
    }

    // MARK: - Library

    func addLibrary(_ url: URL) {
        guard let store else { return }
        Task(priority: .utility) {
            let scanner = LibraryScanner(store: store)
            _ = try? await scanner.scan(root: url)
            await refresh()
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
            let engine = SearchEngine(store: store, options: options)

            try? await vectorIndex?.openForSearch()
            // Only publish results if the query hasn't moved on while we worked.
            let found = try await engine.search(plan: plan, vectorIndex: vectorIndex)
            guard text == query else { return }
            results = found
        } catch {
            searchError = error.localizedDescription
            results = []
        }
    }
}
