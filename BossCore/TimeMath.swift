import Foundation

/// Interval algebra used by the planner. All intervals are half-open in spirit: touching ends don't overlap.
public enum TimeMath {
    /// Merges overlapping or touching intervals into a sorted, disjoint list.
    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for interval in sorted {
            if let last = out.last, interval.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                out.append(interval)
            }
        }
        return out
    }

    /// Removes every `cut` interval from `base`.
    public static func subtract(_ base: [DateInterval], _ cuts: [DateInterval]) -> [DateInterval] {
        let cuts = merge(cuts)
        var out: [DateInterval] = []
        for piece in merge(base) {
            var cursor = piece.start
            for cut in cuts where cut.end > cursor && cut.start < piece.end {
                if cut.start > cursor { out.append(DateInterval(start: cursor, end: cut.start)) }
                cursor = max(cursor, cut.end)
                if cursor >= piece.end { break }
            }
            if cursor < piece.end { out.append(DateInterval(start: cursor, end: piece.end)) }
        }
        return out
    }

    public static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }

    public static func pad(_ interval: DateInterval, minutes: Int) -> DateInterval {
        let pad = TimeInterval(minutes * 60)
        return DateInterval(start: interval.start - pad, end: interval.end + pad)
    }

    /// The next 15-minute boundary at or after `date` (epoch-aligned, so it holds in every time zone offset).
    public static func roundUpToQuarter(_ date: Date) -> Date {
        let quarter: TimeInterval = 15 * 60
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / quarter).rounded(.up) * quarter)
    }

    public static func roundUpToQuarter(minutes: Int) -> Int {
        Int((Double(minutes) / 15).rounded(.up)) * 15
    }

    public static func minutes(_ interval: DateInterval) -> Int {
        Int((interval.duration / 60).rounded())
    }

    /// Wall-clock minute-of-day → absolute date on `day`, honouring DST. 1440 maps to the next midnight.
    public static func date(_ day: Date, minuteOfDay: Int, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        if minuteOfDay >= 24 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
        return calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: start)
            ?? start.addingTimeInterval(TimeInterval(minuteOfDay * 60))
    }

    /// ISO-8601 week identifier (Monday-first), e.g. 202642.
    public static func weekKey(_ date: Date, calendar: Calendar) -> Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
    }

    public static func dayKey(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Monday 00:00 of the ISO week containing `date`.
    public static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
