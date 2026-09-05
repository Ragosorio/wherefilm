import Foundation

/// Daily local wall-clock window, including windows crossing midnight. The end
/// is exclusive; equal endpoints mean all day. Calendar handles DST locally.
public struct IndexingWindow: Codable, Sendable, Equatable {
    public let startMinute: Int
    public let endMinute: Int

    public init?(startMinute: Int, endMinute: Int) {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { return nil }
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public init?(_ text: String) {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        func minute(_ piece: Substring) -> Int? {
            let parts = piece.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]),
                  (0..<24).contains(h), (0..<60).contains(m) else { return nil }
            return h * 60 + m
        }
        guard pieces.count == 2, let start = minute(pieces[0]), let end = minute(pieces[1]) else { return nil }
        self.init(startMinute: start, endMinute: end)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    public var description: String {
        String(format: "%02d:%02d–%02d:%02d", startMinute / 60, startMinute % 60,
               endMinute / 60, endMinute % 60)
    }
}
