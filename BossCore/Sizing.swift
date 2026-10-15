import Foundation

/// T-shirt sizes and their stock phase templates. Used when an idea is jotted and whenever offline shaping is unavailable or not requested.
public enum IdeaSize: String, CaseIterable, Sendable, Identifiable {
    case s = "S", m = "M", l = "L", xl = "XL"
    public var id: String { rawValue }

    public var hours: Int {
        switch self {
        case .s: 4
        case .m: 8
        case .l: 20
        case .xl: 45
        }
    }

    public var title: String {
        switch self {
        case .s: "Weekend hack"
        case .m: "Small app"
        case .l: "Real app"
        case .xl: "Big build"
        }
    }

    /// Phase split as (title, share of total).
    var split: [(String, Double)] {
        switch self {
        case .s: [("Blueprint", 0.15), ("Build", 0.65), ("Ship", 0.20)]
        case .m: [("Blueprint", 0.12), ("Prototype", 0.30), ("Core build", 0.38), ("Polish & ship", 0.20)]
        case .l, .xl: [("Blueprint", 0.08), ("Prototype", 0.20), ("Core build", 0.40),
                       ("Polish", 0.20), ("Ship", 0.12)]
        }
    }

    public func phases() -> [Phase] {
        let total = hours * 60
        var used = 0
        var out: [Phase] = []
        for (index, part) in split.enumerated() {
            let minutes = index == split.count - 1
                ? total - used
                : max(30, TimeMath.roundUpToQuarter(minutes: Int(Double(total) * part.1)))
            used += minutes
            out.append(Phase(title: part.0, plannedMinutes: minutes))
        }
        return out
    }

    public static func nearest(hours: Double) -> IdeaSize {
        allCases.min { abs(Double($0.hours) - hours) < abs(Double($1.hours) - hours) } ?? .m
    }
}

public enum BossMeaning {
    /// Human meaning of the weekly hours budget (Station Stepper).
    public static func budget(_ hours: Int) -> String {
        switch hours {
        case ..<6: "Side quest"
        case 6...12: "Steady"
        case 13...20: "Crunch"
        default: "Founder mode"
        }
    }

    public static func heat(_ heat: Int) -> String {
        switch heat {
        case ...1: "Someday"
        case 2: "Curious"
        case 3: "Keen"
        case 4: "Itching"
        default: "Obsessed"
        }
    }
}

public enum BossFormat {
    /// "1:45" for durations under a day; whole hours and minutes, never seconds.
    public static func clock(minutes: Int) -> String {
        let m = max(0, minutes)
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "1.5 h", "8 h", "45 min".
    public static func hours(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = Double(minutes) / 60
        return h.rounded() == h ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }

    public static func hoursValue(minutes: Int) -> String {
        let h = Double(minutes) / 60
        return h.rounded() == h ? "\(Int(h))" : String(format: "%.1f", h)
    }

    public static func spokenDuration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) minutes"
        case (_, 0): return h == 1 ? "1 hour" : "\(h) hours"
        default: return "\(h) hour\(h == 1 ? "" : "s") \(m) minutes"
        }
    }
}
