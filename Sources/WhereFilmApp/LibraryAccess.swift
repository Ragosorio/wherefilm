import Foundation

/// Keeps access to the folders a person explicitly selected. The original
/// files remain in place; only bookmark tokens are persisted.
@MainActor
final class LibraryAccess {
    private let defaultsKey = "wherefilm.libraryBookmarks.v1"
    private var activeURLs: [URL] = []

    func restore() -> [URL] {
        let bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var restored: [URL] = []
        var refreshed: [Data] = []

        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }

            _ = url.startAccessingSecurityScopedResource()
            activeURLs.append(url)
            restored.append(url)

            if stale, let replacement = try? makeBookmark(for: url) {
                refreshed.append(replacement)
            } else {
                refreshed.append(bookmark)
            }
        }

        UserDefaults.standard.set(refreshed, forKey: defaultsKey)
        return restored
    }

    func remember(_ url: URL) throws {
        if !activeURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            _ = url.startAccessingSecurityScopedResource()
            activeURLs.append(url)
        }

        var bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        let bookmark = try makeBookmark(for: url)

        // Resolve before comparing: bookmark bytes are not guaranteed to be
        // stable for the same URL.
        let alreadyStored = bookmarks.contains { data in
            var stale = false
            guard let stored = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return false }
            return stored.standardizedFileURL == url.standardizedFileURL
        }
        if !alreadyStored { bookmarks.append(bookmark) }
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
