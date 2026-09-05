import Foundation
import ArgumentParser
import WhereFilmCore
import WhereFilmML

struct Sidecar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move one volume's indexed knowledge between Macs, without reprocessing media.",
        subcommands: [ExportSidecar.self, ImportSidecar.self, InspectSidecar.self])
}
struct ExportSidecar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export a volume to a new .wfindex directory. Excludes people, usage, bookmarks and previews.")
    @OptionGroup var storeOptions: StoreOptions
    @Option(name: .long, help: "Persistent volume UUID from wherefilm volumes.") var volume: String
    @Argument(help: "New .wfindex directory.") var destination: String
    func run() async throws {
        let store = try storeOptions.makeStore()
        let manifest = try PortableCatalog.export(store: store, volumeUUID: volume,
            to: URL(fileURLWithPath: (destination as NSString).expandingTildeInPath))
        print("Exported \(manifest.assets) assets and \(manifest.moments) moments. Original media were not read.")
    }
}
struct InspectSidecar: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Verify the snapshot checksum and print its manifest.")
    @Argument var path: String
    func run() throws {
        let manifest = try PortableCatalog.inspect(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(manifest), as: UTF8.self))
    }
}
struct ImportSidecar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Merge a snapshot into this catalog. Existing analysis wins; IDs are remapped.")
    @OptionGroup var storeOptions: StoreOptions
    @Argument var path: String
    func run() async throws {
        let store = try storeOptions.makeStore()
        let report = try PortableCatalog.importCatalog(
            from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), into: store)
        print("Imported \(report.addedAssets) new assets, \(report.addedMoments) moments, \(report.addedLocations) locations; preserved \(report.existingAssets) existing assets.")
        // The destination's IDs differ. Never install the other Mac's ANN file.
        // Rebuild from compact stored vectors, without touching original media.
        for variant in MobileCLIPVariant.allCases {
            guard try store.embeddingCount(modelID: variant.modelID) > 0 else { continue }
            let index = try makeVectorIndex(variant: variant, store: store)
            try await index.rebuild(from: store)
        }
        print("Search index ready. Locations stay offline until the volume is scanned on this Mac.")
    }
}
