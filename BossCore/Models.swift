import Foundation

// Boss Calendar domain model. Everything persistent lives in one Codable BossState value.

public enum IdeaTrack: String, Codable, Sendable, CaseIterable, Identifiable {
    case queued, note, paused, shipped
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queued: "Build"
        case .note: "Note"
        case .paused: "Paused"
        case .shipped: "Shipped"
        }
    }
}

public enum ShapeSource: String, Codable, Sendable {
    case template, appleIntelligence, manual, qwen2B, qwen4B
    public var title: String {
        switch self {
        case .template: "Size template"
        case .appleIntelligence: "Apple Intelligence"
        case .manual: "Manual"
        case .qwen2B: "Qwen 2B"
        case .qwen4B: "Qwen 4B"
        }
    }
}

public struct Phase: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var plannedMinutes: Int
    public var doneMinutes: Int

    public init(id: UUID = UUID(), title: String, plannedMinutes: Int, doneMinutes: Int = 0) {
        self.id = id
        self.title = title
        self.plannedMinutes = max(0, plannedMinutes)
        self.doneMinutes = max(0, doneMinutes)
    }

    public var remainingMinutes: Int { max(0, plannedMinutes - doneMinutes) }
}

public struct Idea: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var track: IdeaTrack
    public var heat: Int
    public var deadline: Date?
    public var phases: [Phase]
    public var shapedBy: ShapeSource

    public init(id: UUID = UUID(), title: String, body: String = "", createdAt: Date = .now,
                track: IdeaTrack = .queued, heat: Int = 3, deadline: Date? = nil,
                phases: [Phase] = [], shapedBy: ShapeSource = .template) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.track = track
        self.heat = min(5, max(1, heat))
        self.deadline = deadline
        self.phases = phases
        self.shapedBy = shapedBy
    }

    public var plannedMinutes: Int { phases.reduce(0) { $0 + $1.plannedMinutes } }
    public var doneMinutes: Int { phases.reduce(0) { $0 + min($1.doneMinutes, $1.plannedMinutes) } }
    public var remainingMinutes: Int { phases.reduce(0) { $0 + $1.remainingMinutes } }
    public var progress: Double {
        plannedMinutes == 0 ? 0 : Double(doneMinutes) / Double(plannedMinutes)
    }
    public var currentPhase: Phase? { phases.first { $0.remainingMinutes > 0 } }

    /// Credits worked minutes to phases in order.
    public mutating func credit(minutes: Int) {
        var left = minutes
        for index in phases.indices where left > 0 {
            let take = min(left, phases[index].remainingMinutes)
            phases[index].doneMinutes += take
            left -= take
        }
        if left > 0, !phases.isEmpty {
            phases[phases.count - 1].doneMinutes += left
        }
        updatedAt = .now
    }
}

public enum BlockState: String, Codable, Sendable {
    case planned, done, skipped
}

public struct Block: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var ideaID: UUID
    public var phaseTitle: String
    public var start: Date
    public var end: Date
    public var state: BlockState
    public var locked: Bool

    public init(id: UUID = UUID(), ideaID: UUID, phaseTitle: String, start: Date, end: Date,
                state: BlockState = .planned, locked: Bool = false) {
        self.id = id
        self.ideaID = ideaID
        self.phaseTitle = phaseTitle
        self.start = start
        self.end = end
        self.state = state
        self.locked = locked
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
}

public struct Nudge: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var due: Date
    public var ideaID: UUID?
    public var done: Bool

    public init(id: UUID = UUID(), title: String, due: Date, ideaID: UUID? = nil, done: Bool = false) {
        self.id = id
        self.title = title
        self.due = due
        self.ideaID = ideaID
        self.done = done
    }
}

/// One recurring weekly build window. weekday follows Calendar: 1 = Sunday … 7 = Saturday.
public struct BuildWindow: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var weekday: Int
    public var startMinute: Int
    public var endMinute: Int

    public init(id: UUID = UUID(), weekday: Int, startMinute: Int, endMinute: Int) {
        self.id = id
        self.weekday = min(7, max(1, weekday))
        self.startMinute = min(24 * 60, max(0, startMinute))
        self.endMinute = min(24 * 60, max(0, endMinute))
    }

    public var minutes: Int { max(0, endMinute - startMinute) }

    public static func h(_ weekday: Int, _ start: Double, _ end: Double) -> BuildWindow {
        BuildWindow(weekday: weekday, startMinute: Int(start * 60), endMinute: Int(end * 60))
    }

    public static let defaults: [BuildWindow] = [
        .h(2, 19, 22), .h(3, 19, 22), .h(4, 19, 22), .h(5, 19, 22), .h(6, 19, 21),
        .h(7, 10, 13), .h(7, 14, 17.5), .h(1, 11, 14)
    ]
}

public struct PlannerSettings: Codable, Sendable, Hashable {
    public var weeklyBudgetHours: Int = 12
    public var blockMinutes: Int = 90
    public var minBlockMinutes: Int = 45
    public var breakMinutes: Int = 15
    public var maxBlocksPerDay: Int = 2
    public var focusLimit: Int = 2
    public var busyBufferMinutes: Int = 10
    public var horizonDays: Int = 21
    public var freezeHours: Int = 12
    public var useAppleCalendar: Bool = true
    public var notifyBlocks: Bool = true
    public var leadMinutes: Int = 5

    public init() {}
}

public struct BossState: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var ideas: [Idea] = []
    public var blocks: [Block] = []
    public var nudges: [Nudge] = []
    public var windows: [BuildWindow] = BuildWindow.defaults
    public var settings = PlannerSettings()
    public var lastPlannedAt: Date?

    public init() {}

    public func idea(_ id: UUID) -> Idea? { ideas.first { $0.id == id } }
}
