import Foundation

/// A volume as macOS currently sees it.
public struct MountedVolume: Sendable, Hashable {
    public let uuid: String
    public let name: String
    public let mountURL: URL
    public let fsType: String?
    public let isRemovable: Bool

    public init(uuid: String, name: String, mountURL: URL, fsType: String?, isRemovable: Bool) {
        self.uuid = uuid
        self.name = name
        self.mountURL = mountURL
        self.fsType = fsType
        self.isRemovable = isRemovable
    }
}

/// Resolves paths to (volume UUID, path relative to the volume root).
///
/// This is the piece that makes the index survive `/Volumes/Media` becoming
/// `/Volumes/Media 1` after a remount — a failure mode Peakto documents and that
/// any path-keyed catalogue eventually hits.
public struct VolumeRegistry: Sendable {
    public init() {}

    public func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeUUIDStringKey, .volumeNameKey, .volumeURLKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            // A volume with no UUID (some network mounts) gets a stable synthetic
            // one derived from its name, which is better than nothing and still
            // never a path.
            let uuid = values.volumeUUIDString ?? syntheticUUID(for: url, name: values.volumeName)
            return MountedVolume(
                uuid: uuid,
                name: values.volumeName ?? url.lastPathComponent,
                mountURL: values.volume ?? url,
                fsType: values.volumeLocalizedFormatDescription,
                isRemovable: values.volumeIsRemovable ?? false
            )
        }
    }

    /// Which volume does this URL live on, and what is its path relative to that
    /// volume's root?
    public func resolve(_ url: URL) -> (volume: MountedVolume, relativePath: String)? {
        let standardized = url.standardizedFileURL
        // Longest mount path wins: `/Volumes/Foo/Bar` belongs to `/Volumes/Foo`,
        // not to `/`.
        let candidates = mountedVolumes()
            .filter { standardized.path.hasPrefix(normalizedPrefix($0.mountURL)) || $0.mountURL.path == "/" }
            .sorted { $0.mountURL.path.count > $1.mountURL.path.count }

        guard let volume = candidates.first else { return nil }
        let root = volume.mountURL.path == "/" ? "/" : normalizedPrefix(volume.mountURL)
        var relative = String(standardized.path.dropFirst(root.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return (volume, relative)
    }

    /// Rebuilds an absolute URL from a stored (volume UUID, relative path) pair —
    /// returns nil when the drive simply isn't plugged in, which is `offline`,
    /// not `missing`.
    public func absoluteURL(volumeUUID: String, relativePath: String) -> URL? {
        guard let volume = mountedVolumes().first(where: { $0.uuid == volumeUUID }) else {
            return nil
        }
        return volume.mountURL.appendingPathComponent(relativePath)
    }

    public func isOnline(volumeUUID: String) -> Bool {
        mountedVolumes().contains { $0.uuid == volumeUUID }
    }

    private func normalizedPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func syntheticUUID(for url: URL, name: String?) -> String {
        "name:" + (name ?? url.lastPathComponent)
    }
}
