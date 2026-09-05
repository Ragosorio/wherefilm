import Foundation
import CryptoKit
import GRDB

/// Local, bounded usage history for one catalog. Never included in sidecars.
extension IndexStore {
    public enum InteractionAction: String, Sendable, Codable, CaseIterable {
        case open, seek, pin, reformulate
    }

    public static let learningChannels: Set<String> = [
        "visual", "transcript", "ocr", "label", "person", "metadata"
    ]

    public func usageLearningEnabled() throws -> Bool {
        try dbPool.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM usage_state WHERE id = 1") ?? false }
    }

    public func setUsageLearningEnabled(_ enabled: Bool) throws {
        try dbPool.write {
            try $0.execute(sql: "UPDATE usage_state SET enabled = ?, revision = revision + 1 WHERE id = 1",
                           arguments: [enabled])
        }
    }

    public func usageRevision() throws -> Int64 {
        try dbPool.read { try Int64.fetchOne($0, sql: "SELECT revision FROM usage_state WHERE id = 1") ?? 0 }
    }

    /// Callers supply actions they actually observed. No dwell time is inferred
    /// from opening an external player. Disabled catalogs record nothing.
    public func record(action: InteractionAction, query: String, assetID: Int64? = nil,
                       momentID: Int64? = nil, rank: Int? = nil,
                       dwellMilliseconds: Int? = nil, channels: [String] = []) throws {
        let channels = Set(channels).intersection(Self.learningChannels).sorted()
        guard !channels.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try dbPool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT enabled FROM usage_state WHERE id = 1") == true,
                  let key = try Data.fetchOne(db, sql: "SELECT queryKey FROM usage_state WHERE id = 1") else { return }
            let normalized = query.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                           locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let hash = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: SymmetricKey(data: key))
                .map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: """
                INSERT INTO interactions(queryHash, assetID, momentID, action, rank,
                    dwellMilliseconds, channels, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [hash, assetID, momentID, action.rawValue, rank,
                                   dwellMilliseconds.map { max(0, $0) }, channels.joined(separator: ","), Date()])
            try db.execute(sql: """
                DELETE FROM interactions WHERE id <= (
                    SELECT id FROM interactions ORDER BY id DESC LIMIT 1 OFFSET 5000
                )
                """)
        }
    }

    public struct ChannelPreference: Sendable, Codable {
        public let channel: String
        public let samples: Int
        public let rewards: Int
        public let multiplier: Double
    }

    /// Smoothed channel success rates, not a trained relevance model. The
    /// conservative 15% bound and 200-event warmup are safeguards, not evidence
    /// of better retrieval. Promotion needs evaluation on real user feedback.
    public func channelPreferences(minimumSamples: Int = 200,
                                   maximumShift: Double = 0.15) throws -> [ChannelPreference] {
        let rows = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, channels, dwellMilliseconds FROM interactions
                WHERE channels IS NOT NULL ORDER BY id DESC LIMIT 2000
                """)
        }
        guard rows.count >= max(1, minimumSamples) else { return [] }
        var samples: [String: Int] = [:]
        var rewards: [String: Int] = [:]
        for row in rows {
            guard let raw: String = row["action"], let action = InteractionAction(rawValue: raw),
                  let text: String = row["channels"] else { continue }
            // A seek is positive only after actual playback, not on a click.
            if action == .seek, (row["dwellMilliseconds"] as Int? ?? 0) < 3000 { continue }
            for channel in Set(text.split(separator: ",").map(String.init)).intersection(Self.learningChannels) {
                samples[channel, default: 0] += 1
                if action != .reformulate { rewards[channel, default: 0] += 1 }
            }
        }
        let total = samples.values.reduce(0, +)
        let won = rewards.values.reduce(0, +)
        guard total > 0, won > 0, won < total else { return [] }
        let average = Double(won + 10) / Double(total + 20)
        let shift = maximumShift.isFinite ? min(0.15, max(0, maximumShift)) : 0
        return samples.keys.sorted().map { channel in
            let seen = samples[channel, default: 0]
            let rewarded = rewards[channel, default: 0]
            let rate = (Double(rewarded) + 20 * average) / Double(seen + 20)
            let multiplier = seen < 10 ? 1 : min(1 + shift, max(1 - shift, rate / average))
            return ChannelPreference(channel: channel, samples: seen, rewards: rewarded, multiplier: multiplier)
        }
    }

    public func interactionCount() throws -> Int {
        try dbPool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM interactions") ?? 0 }
    }

    /// Inspection exports aggregates only: no search hashes, paths or key.
    public struct UsageReport: Codable, Sendable {
        public let enabled: Bool
        public let interactions: Int
        public let minimumSamples: Int
        public let channels: [ChannelPreference]
    }

    public func usageReport() throws -> UsageReport {
        try UsageReport(enabled: usageLearningEnabled(), interactions: interactionCount(),
                        minimumSamples: 200, channels: channelPreferences())
    }

    /// Invalidate cached weights immediately and rotate the per-catalog key.
    public func forgetUsage() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM interactions")
            try db.execute(sql: "UPDATE usage_state SET queryKey = randomblob(32), revision = revision + 1 WHERE id = 1")
        }
    }
}
