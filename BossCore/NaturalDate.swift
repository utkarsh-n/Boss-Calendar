import Foundation

/// Finds a date in jotted text ("call Sam fri 5pm") and returns it with the remaining title.
public enum NaturalDate {
    public struct Match: Sendable {
        public var date: Date
        public var title: String
    }

    public static func parse(_ text: String, now: Date = .now) -> Match? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let hit = detector.firstMatch(in: text, options: [], range: range), var date = hit.date,
              let swiftRange = Range(hit.range, in: text) else { return nil }
        // Bare times that already passed today mean tomorrow.
        if date < now && now.timeIntervalSince(date) < 86_400 { date = date.addingTimeInterval(86_400) }
        var title = text
        title.removeSubrange(swiftRange)
        title = title.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in [" at", " on", " by"] where title.lowercased().hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return Match(date: date, title: title.isEmpty ? text : title)
    }
}
