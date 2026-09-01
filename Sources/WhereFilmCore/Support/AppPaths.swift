import Foundation

/// Every path WhereFilm writes to. Nothing is ever written next to the user's
/// originals unless they explicitly enable sidecars.
public enum AppPaths {
    public static let bundleFolderName = "WhereFilm"

    /// Overrides every path below. Set `WHEREFILM_HOME` to keep a test run, a
    /// second library, or a benchmark completely isolated from the real index.
    public static var overrideRoot: URL? {
        ProcessInfo.processInfo.environment["WHEREFILM_HOME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// `~/Library/Application Support/WhereFilm`
    public static var support: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleFolderName, isDirectory: true)
    }

    /// `~/Library/Caches/WhereFilm` — previews live here, and only here.
    /// Anything in this folder must be regenerable.
    public static var caches: URL {
        if let overrideRoot { return overrideRoot.appendingPathComponent("Caches", isDirectory: true) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleFolderName, isDirectory: true)
    }

    public static var database: URL { support.appendingPathComponent("index.sqlite") }

    /// Writable model location used by the CLI and development builds.
    public static var installedModels: URL {
        support.appendingPathComponent("Models", isDirectory: true)
    }

    /// A release build ships the visual models inside the application bundle so
    /// a first-time user never has to open Terminal or download a second piece.
    public static var bundledModels: URL? {
        return Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true)
    }

    /// Prefer a user-installed model set, then fall back to the self-contained
    /// application bundle.
    ///
    /// `WHEREFILM_HOME` stays deterministic because an isolated home that has
    /// its own models always wins. It deliberately does *not* short-circuit the
    /// bundle fallback: that fallback is the path every downloaded copy takes,
    /// and making it unreachable under an isolated home would leave the one
    /// branch that matters most as the one branch nothing could test.
    public static var models: URL {
        if directoryContainsFiles(installedModels) { return installedModels }
        if let bundledModels, directoryContainsFiles(bundledModels) { return bundledModels }
        return installedModels
    }
    public static var vectorIndexes: URL { support.appendingPathComponent("Vectors", isDirectory: true) }
    public static var previews: URL { caches.appendingPathComponent("Previews", isDirectory: true) }

    public static func vectorIndex(for modelID: String) -> URL {
        vectorIndexes.appendingPathComponent("\(modelID).usearch")
    }

    /// Creates every directory the app needs. Safe to call repeatedly.
    public static func createDirectories() throws {
        let fm = FileManager.default
        for url in [support, caches, installedModels, vectorIndexes, previews] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // Deliberately absent: a routine that copies the bundled models into
    // writable storage on first launch.
    //
    // It was written, measured, and removed. The theory was that a read-only
    // bundle stops Core ML from rebuilding a stale Neural Engine artifact. The
    // measurement said the opposite: copying the `.mlmodelc` elsewhere is itself
    // what invalidates that artifact, so the copy *guaranteed* the ANE failure
    // it was meant to prevent, and indexing the same seven-file fixture went
    // from 13 seconds to 15 minutes 38 on CPU.
    //
    // Loaded from where it ships, the model gets the Neural Engine. The
    // remaining risk — a machine that rejects the artifact anyway — is handled
    // where it belongs, by the CPU fallback in `MobileCLIPLoader.load`.

    private static func directoryContainsFiles(_ url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return !contents.isEmpty
    }
}
