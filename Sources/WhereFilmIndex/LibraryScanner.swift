import Foundation
import WhereFilmCore

public struct ScanReport: Sendable {
    public var filesSeen = 0
    public var newAssets = 0
    public var newLocations = 0
    public var rebound = 0
    public var renamed = 0
    public var markedMissing = 0
    public var skipped = 0
    public var errors: [String] = []
}

/// Walks a folder or a whole drive and turns files into assets and locations.
///
/// The originals are never copied or moved. This is the *catalog in place* model
/// that professional MAM systems settle on: point at the storage that already
/// exists, keep the intelligence separately, and let the footage stay where it
/// lives.
public struct LibraryScanner: Sendable {
    public struct Options: Sendable {
        public var followSymlinks = false
        public var skipHiddenFiles = true
        /// Folders that are never worth walking into.
        public var excludedDirectoryNames: Set<String> = [
            ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
            "CachedFiles", "Proxies", "Render Files", "node_modules",
        ]
        /// Ignore stubs. A 4 KB .mov is a placeholder, not footage — but a
        /// thumbnail-sized HEIC is still a real photo, so the floors differ.
        public var minimumVideoSize: Int64 = 64 * 1024
        public var minimumImageSize: Int64 = 2 * 1024
        public var enqueueTranscription = true

        public init() {}
    }

    let store: IndexStore
    let volumes: VolumeRegistry
    let probe = MediaProbe()
    /// Optional live policy. Discovery is cheap enough to continue in editor
    /// quiet mode, but it yields under a user pause or critical thermal state.
    public var governor: ResourceGovernor?
    public var options: Options

    public init(store: IndexStore, volumes: VolumeRegistry = VolumeRegistry(),
                options: Options = Options(), governor: ResourceGovernor? = nil) {
        self.store = store
        self.volumes = volumes
        self.options = options
        self.governor = governor
    }

    /// Refreshes which volumes are mounted. Unplugging a drive makes its files
    /// `offline` — never `missing`, and never forgotten.
    public func syncVolumes() throws {
        let mounted = volumes.mountedVolumes()
        for volume in mounted {
            let existing = try store.volume(uuid: volume.uuid)
            try store.upsertVolume(Volume(
                volumeUUID: volume.uuid,
                name: volume.name,
                fsType: volume.fsType,
                isOnline: true,
                lastSeenAt: Date(),
                bookmark: existing?.bookmark))
        }
        try store.markVolumes(online: Set(mounted.map(\.uuid)))
    }

    public func scan(root: URL,
                     progress: (@Sendable (Int, URL) -> Void)? = nil) async throws -> ScanReport {
        try await waitForDiscoveryPermission()
        try syncVolumes()

        var report = ScanReport()
        guard let resolvedRoot = volumes.resolve(root) else {
            report.errors.append("Could not determine which volume \(root.path) lives on.")
            return report
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .isHiddenKey,
        ]
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if options.skipHiddenFiles { enumeratorOptions.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: enumeratorOptions)
        else {
            report.errors.append("Could not read \(root.path).")
            return report
        }

        var seenPaths: Set<String> = []

        while let next = enumerator.nextObject() {
            try Task.checkCancellation()
            if report.filesSeen > 0, report.filesSeen % 64 == 0 {
                try await waitForDiscoveryPermission()
            }
            guard let url = next as? URL else { continue }
            if options.excludedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            guard let kind = MediaProbe.mediaType(for: url) else { continue }

            let fileSize = Int64(values.fileSize ?? 0)
            let floor = kind == .image ? options.minimumImageSize : options.minimumVideoSize
            guard fileSize >= floor else {
                report.skipped += 1
                continue
            }

            report.filesSeen += 1
            progress?(report.filesSeen, url)

            do {
                let outcome = try await ingest(
                    url: url, fileSize: fileSize,
                    modifiedAt: values.contentModificationDate,
                    seenPaths: &seenPaths)
                switch outcome {
                case .newAsset: report.newAssets += 1
                case .newLocation: report.newLocations += 1
                case .rebound: report.rebound += 1
                case .renamed: report.renamed += 1
                }
            } catch {
                report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }

            // The scanner is background work; let anything else on the machine
            // have the CPU whenever it wants it.
            await Task.yield()
        }

        // Anything under the folder we just walked that we didn't see is gone
        // from disk. Scoping to that prefix is what keeps scanning one folder
        // from declaring the rest of the drive missing.
        report.markedMissing = try store.markMissing(
            volumeUUID: resolvedRoot.volume.uuid,
            pathPrefix: resolvedRoot.relativePath,
            seenPaths: seenPaths)
        // Runs last, so a file that moved within this scan ends up with exactly
        // one location instead of a live one plus a stale one.
        _ = try store.pruneRedundantMissingLocations()

        return report
    }

    private func waitForDiscoveryPermission() async throws {
        guard let governor else { return }
        while !Task.isCancelled {
            if governor.decide().scanConcurrency > 0 { return }
            try await Task.sleep(for: .seconds(2))
        }
        try Task.checkCancellation()
    }

    enum IngestOutcome {
        case newAsset
        case newLocation
        case rebound
        case renamed
    }

    func ingest(url: URL, fileSize: Int64, modifiedAt: Date?,
                seenPaths: inout Set<String>) async throws -> IngestOutcome {
        guard let resolved = volumes.resolve(url) else {
            throw ScanError.unresolvedVolume(url)
        }
        seenPaths.insert(resolved.relativePath)

        // Repeat scans must be proportional to the directory listing, not to
        // the number of bytes in the library. Filesystems already maintain a
        // cheap revision tuple for us: path + size + modification date. When it
        // matches the catalog, no media probe or content hash can teach us
        // anything new. This turns a rescan of 100 GB / 1 TB / 30 TB from
        // "re-open every movie" into metadata lookups, while a changed or moved
        // file still falls through to full content identity below.
        if let previous = try store.location(
            volumeUUID: resolved.volume.uuid,
            relativePath: resolved.relativePath),
           Self.isSameRevision(previous, fileSize: fileSize, modifiedAt: modifiedAt) {
            try store.upsertLocation(Location(
                locationID: previous.locationID,
                assetID: previous.assetID,
                volumeUUID: previous.volumeUUID,
                relativePath: previous.relativePath,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                availability: .online))
            return .rebound
        }

        let info = try await probe.probe(url: url)
        let contentKey = try ContentKey.quick(
            url: url, fileSize: fileSize,
            durationSeconds: info.durationSeconds, codec: info.codec)

        // The same footage on an SSD, a backup drive and a NAS is one asset with
        // three locations — not three videos.
        if let existing = try store.asset(contentKey: contentKey), let assetID = existing.assetID {
            let hadLocation = try store.locations(assetID: assetID)
                .contains { $0.volumeUUID == resolved.volume.uuid && $0.relativePath == resolved.relativePath }
            try store.upsertLocation(Location(
                assetID: assetID, volumeUUID: resolved.volume.uuid,
                relativePath: resolved.relativePath, fileSize: fileSize,
                modifiedAt: modifiedAt, availability: .online))

            // Identity survives a rename by design — the content key never looks
            // at the path. But the *searchable* name did not: the filename and
            // folder rows in the FTS index are written once, by the metadata
            // job, and a renamed file only ever re-ran that job if it looked
            // like a brand new asset. So renaming a file left the old name in
            // the index and the new one unfindable. Refresh it here, where we
            // have both names in hand and the probe has already run.
            let filename = url.lastPathComponent
            if filename != existing.displayName {
                var updated = existing
                updated.displayName = filename
                try store.update(updated)
                try store.indexMetadataText(
                    assetID: assetID,
                    filename: filename,
                    folder: url.deletingLastPathComponent().lastPathComponent,
                    camera: info.cameraDescription)
                return .renamed
            }
            if !hadLocation {
                // A move that keeps the filename still changes the searchable
                // folder. Refresh the metadata row so an asset moved from
                // `Exports` to `Client-A` follows the new location.
                try store.indexMetadataText(
                    assetID: assetID,
                    filename: existing.displayName,
                    folder: url.deletingLastPathComponent().lastPathComponent,
                    camera: info.cameraDescription)
            }
            return hadLocation ? .rebound : .newLocation
        }

        let asset = try store.insert(Asset(
            contentKey: contentKey,
            mediaType: info.mediaType,
            durationSeconds: info.durationSeconds,
            width: info.width, height: info.height,
            createdAt: info.createdAt,
            cameraMake: info.cameraMake, cameraModel: info.cameraModel,
            displayName: url.lastPathComponent))

        guard let assetID = asset.assetID else { throw ScanError.insertFailed }

        try store.upsertLocation(Location(
            assetID: assetID, volumeUUID: resolved.volume.uuid,
            relativePath: resolved.relativePath, fileSize: fileSize,
            modifiedAt: modifiedAt, availability: .online))

        var tasks: [JobTask] = [.metadata, .visual]
        if options.enqueueTranscription && info.hasAudio && info.mediaType != .image {
            tasks.append(.transcribe)
        }
        try store.enqueue(assetID: assetID, tasks: tasks)

        return .newAsset
    }

    /// Both dates must exist. A filesystem that cannot provide a modification
    /// time gets the conservative path and is probed again; silently trusting
    /// size alone would miss replacements with equal byte counts.
    static func isSameRevision(_ location: Location, fileSize: Int64,
                               modifiedAt: Date?) -> Bool {
        guard location.fileSize == fileSize,
              let oldDate = location.modifiedAt,
              let newDate = modifiedAt else { return false }
        // GRDB and Foundation can round through different timestamp precisions.
        return abs(oldDate.timeIntervalSince(newDate)) < 0.001
    }

}

public enum ScanError: Error, LocalizedError {
    case unresolvedVolume(URL)
    case insertFailed

    public var errorDescription: String? {
        switch self {
        case .unresolvedVolume(let url):
            "Could not determine which volume \(url.path) lives on."
        case .insertFailed:
            "Failed to create the asset record."
        }
    }
}
