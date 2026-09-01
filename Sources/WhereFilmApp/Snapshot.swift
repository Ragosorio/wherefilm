import SwiftUI
import AppKit

/// Lets a release build prove, from inside its own process, that the interface
/// really renders — and hand back a retina picture of itself.
///
/// Two things made this worth building rather than reaching for a screenshot
/// utility. A screen capture photographs whatever else happens to be on the
/// display, which is a privacy surface a search tool has no business opening;
/// and the accessibility APIs that would inspect the window need a permission
/// prompt, which makes verification depend on someone clicking a dialog.
/// `ImageRenderer` needs neither: it lays the view out offscreen and rasterises
/// it deterministically at whatever scale is asked for.
///
/// Activated only by environment variables, so it is inert in the build a
/// person downloads.
@MainActor
enum Snapshot {
    static var isRequested: Bool {
        environment("WHEREFILM_QA_SNAPSHOT") != nil || environment("WHEREFILM_QA_REPORT") != nil
    }

    /// Waits for the demo query to settle, writes whatever was asked for, and
    /// exits with a status that a script can branch on.
    static func runIfRequested() {
        guard isRequested else { return }
        Task { await run() }
    }

    private static func run() async {
        let model = AppModel.shared
        let budget = Double(environment("WHEREFILM_QA_TIMEOUT") ?? "") ?? 240
        let deadline = Date().addingTimeInterval(budget)

        // Wait for the engine rather than for a fixed sleep. A cold start pays
        // for compiling and loading the Core ML text encoder once, and when the
        // run also indexes a fresh library it has to wait for the background
        // indexer to actually produce moments — both costs differ per machine.
        var lastMoments = -1
        var quietPolls = 0
        while Date() < deadline {
            if model.stats.moments != lastMoments {
                lastMoments = model.stats.moments
                quietPolls = 0
            } else {
                quietPolls += 1
            }
            // The indexer has stopped producing and nothing is in flight: retry
            // the query once against everything that did get indexed.
            if quietPolls == 8, model.stats.moments > 0, model.results.isEmpty,
               !model.query.isEmpty, !model.isSearching {
                await model.runSearch()
            }
            // A query expected to find nothing has no "results arrived" signal,
            // so it waits for the indexer to actually finish instead. Both
            // conditions are needed: "no new moments for a while" alone fires
            // during a slow video, and "nothing in flight" alone fires in the
            // gap between two jobs — and asserting that nothing matched a
            // quarter-built index would prove almost nothing.
            let expectsEmpty = environment("WHEREFILM_QA_EXPECT_EMPTY") != nil
            let indexerIdle = model.currentActivity == nil && quietPolls >= 24
            let answered = expectsEmpty ? indexerIdle : !model.results.isEmpty
            let settled = !model.isSearching
                && (model.query.isEmpty || answered || model.searchError != nil)
            if settled, model.stats.assets > 0, model.stats.moments > 0 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // One more beat so the grid has laid out its thumbnails.
        try? await Task.sleep(for: .milliseconds(600))

        var failures: [String] = []

        let window = NSApp.windows.first { $0.identifier?.rawValue == SearchWindowID }
        if let window {
            let size = window.frame.size
            print("window   : \(Int(size.width))×\(Int(size.height)) — “\(window.title)”")
            if size.width < 820 || size.height < 620 {
                failures.append("search window is smaller than its declared minimum")
            }
        } else {
            failures.append("no search window exists")
        }

        print("library  : \(model.stats.assets) assets · \(model.stats.moments) moments")
        print("query    : “\(model.query)”")
        print("results  : \(model.results.count)")
        for result in model.results.prefix(5) {
            let percent = Int((result.score * 100).rounded())
            let preview = result.previewPath == nil ? "no preview" : "preview ok"
            print("  · \(result.displayName) — \(percent)% — \(preview)")
        }
        if let error = model.searchError { failures.append("search error: \(error)") }
        if let error = model.startupError { failures.append("startup error: \(error)") }
        if model.stats.assets == 0 { failures.append("index is empty — nothing was verified") }

        // A query that *should* find nothing is as much a requirement as one
        // that should find something: "un plato de espagueti" over a library of
        // landscapes must return zero, not the least-bad landscape.
        let expectsEmpty = environment("WHEREFILM_QA_EXPECT_EMPTY") != nil
        if !model.query.isEmpty {
            if expectsEmpty, !model.results.isEmpty {
                failures.append("a query with no honest answer returned \(model.results.count)")
            } else if !expectsEmpty, model.results.isEmpty {
                failures.append("the demo query returned nothing")
            }
        }
        if model.results.contains(where: { $0.previewPath == nil }) {
            failures.append("a result has no cached preview, so its card would render blank")
        }

        if let path = environment("WHEREFILM_QA_SNAPSHOT") {
            do {
                let size = try write(to: URL(fileURLWithPath: path), model: model)
                print("snapshot : \(path) — \(size.width)×\(size.height) px")
            } catch {
                failures.append("snapshot failed: \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            print("\nOK — the interface rendered and the search returned usable results.")
            exit(0)
        }
        print("\nFAILED:")
        for failure in failures { print("  ✗ \(failure)") }
        exit(1)
    }

    /// Renders the real search interface, with the real index behind it, at 2×.
    private static func write(to url: URL, model: AppModel) throws -> CGSize {
        let width = Double(environment("WHEREFILM_QA_WIDTH") ?? "") ?? 1440
        let height = Double(environment("WHEREFILM_QA_HEIGHT") ?? "") ?? 960

        let renderer = ImageRenderer(
            content: SearchView()
                .environment(model)
                .frame(width: width, height: height)
                .preferredColorScheme(.dark)
        )
        renderer.scale = 2
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: width, height: height)

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw SnapshotError.renderProducedNothing
        }
        try png.write(to: url)
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    enum SnapshotError: LocalizedError {
        case renderProducedNothing
        var errorDescription: String? {
            "ImageRenderer produced no bitmap for the search view"
        }
    }
}
