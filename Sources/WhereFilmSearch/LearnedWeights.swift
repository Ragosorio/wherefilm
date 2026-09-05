import Foundation
import WhereFilmCore

/// A single bounded cache, keyed by store identity AND persistent revision.
/// Switching catalogs, adding feedback or erasing history invalidates it.
actor LearnedWeights {
    static let shared = LearnedWeights()
    private var store: IndexStore?
    private var revision: Int64 = -1
    private var cached: [String: IndexStore.ChannelPreference] = [:]

    func preferences(store: IndexStore) -> [String: IndexStore.ChannelPreference] {
        guard let revision = try? store.usageRevision(),
              (try? store.usageLearningEnabled()) == true else { return [:] }
        if self.store === store, self.revision == revision { return cached }
        guard let preferences = try? store.channelPreferences() else { return [:] }
        self.store = store
        self.revision = revision
        cached = Dictionary(uniqueKeysWithValues: preferences.map { ($0.channel, $0) })
        return cached
    }
}
