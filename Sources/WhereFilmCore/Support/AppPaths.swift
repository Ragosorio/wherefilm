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
    public static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }
    public static var vectorIndexes: URL { support.appendingPathComponent("Vectors", isDirectory: true) }
    public static var previews: URL { caches.appendingPathComponent("Previews", isDirectory: true) }

    public static func vectorIndex(for modelID: String) -> URL {
        vectorIndexes.appendingPathComponent("\(modelID).usearch")
    }

    /// Creates every directory the app needs. Safe to call repeatedly.
    public static func createDirectories() throws {
        let fm = FileManager.default
        for url in [support, caches, models, vectorIndexes, previews] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
