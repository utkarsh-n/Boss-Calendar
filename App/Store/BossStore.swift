import BossCore
import Foundation
import Observation
import os

/// Single owner and writer of BossState. Every schedule-relevant change re-runs Autopilot.
@MainActor
@Observable
final class BossStore {
    static let shared = BossStore()

    private(set) var state: BossState
    private(set) var forecasts: [UUID: Forecast] = [:]
    private(set) var warnings: [PlanWarning] = []
    private(set) var lastDiff: PlanDiff?
    private(set) var busyEvents: [BusyEvent] = []
    private(set) var calendarAccess: CalendarBridge.Access = .notDetermined
    private(set) var now: Date = .now
    var banner: String?

    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let bridge = CalendarBridge()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var notifyTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.utkarsh.bosscalendar", category: "store")
    @ObservationIgnored private let demoBusy = ProcessInfo.processInfo.arguments.contains("-demoBusy")

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("-resetState"), let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder.boss.decode(BossState.self, from: data) {
            state = saved
        } else {
            state = Seed.state()
        }
        if demoBusy { busyEvents = Self.demoEvents(now: .now, calendar: calendar) }
        replan(announce: false)
    }

    // MARK: - Persistence

    static var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "BossCalendar", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "state.json")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            let data = try JSONEncoder.boss.encode(state)
            try data.write(to: Self.fileURL, options: [.atomic])
        } catch {
            log.error("save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Planning

    /// Applies a change, persists it and (by default) re-plans.
    func mutate(replan shouldReplan: Bool = true, _ change: (inout BossState) -> Void) {
        change(&state)
        if shouldReplan { replan(announce: false) } else { scheduleSave() }
    }

    func replan(announce: Bool = false) {
        now = .now
        let busy = state.settings.useAppleCalendar || demoBusy ? busyEvents.map(\.interval) : []
        let output = Planner.plan(PlanInput(now: now, calendar: calendar, ideas: state.ideas, blocks: state.blocks,
                                            windows: state.windows, busy: busy, settings: state.settings))
        state.blocks = output.blocks
        state.lastPlannedAt = now
        forecasts = output.forecasts
        warnings = output.warnings
        lastDiff = output.diff
        if announce { show(output.diff.summary) }
        scheduleSave()
        scheduleNotifications()
    }

    private func scheduleNotifications() {
        notifyTask?.cancel()
        let snapshot = state
        notifyTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await NotificationScheduler.sync(snapshot)
        }
    }

    /// Foreground entry: refresh the clock and Apple Calendar busy time, then re-plan.
    func refresh() async {
        now = .now
        calendarAccess = await bridge.access()
        if state.settings.useAppleCalendar, calendarAccess == .granted, !demoBusy {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: state.settings.horizonDays + 1, to: start) ?? now
            busyEvents = await bridge.events(from: start, to: end)
        }
        replan()
    }

    func requestCalendarAccess() async {
        calendarAccess = await bridge.requestAccess()
        await refresh()
    }

    func tick() {
        let previous = now
        now = .now
        // A block boundary passed: the past block now needs a check-in, re-derive notifications.
        if state.blocks.contains(where: { $0.end > previous && $0.end <= now }) { replan() }
    }

    func show(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: - Ideas

    @discardableResult
    func addIdea(title: String, body: String = "", track: IdeaTrack = .queued, size: IdeaSize = .m,
                 heat: Int = 3) -> UUID {
        let idea = Idea(title: title, body: body, track: track, heat: heat,
                        phases: track == .note ? [] : size.phases())
        mutate { $0.ideas.insert(idea, at: 0) }
        if track == .queued {
            if let next = forecasts[idea.id]?.nextBlock {
                show("Booked “\(idea.title)” · first block \(Fmt.departure(next))")
            } else {
                show("Queued “\(idea.title)” · no free block in the next \(state.settings.horizonDays) days")
            }
        } else {
            show("Saved note “\(idea.title)”")
        }
        return idea.id
    }

    func update(_ idea: Idea) {
        guard let index = state.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        let old = state.ideas[index]
        var new = idea
        new.updatedAt = .now
        let affectsPlan = old.track != new.track || old.heat != new.heat || old.deadline != new.deadline
            || old.phases.map(\.plannedMinutes) != new.phases.map(\.plannedMinutes)
            || old.phases.map(\.doneMinutes) != new.phases.map(\.doneMinutes)
        mutate(replan: affectsPlan) { $0.ideas[index] = new }
    }

    func deleteIdea(_ id: UUID) {
        mutate {
            $0.ideas.removeAll { $0.id == id }
            $0.blocks.removeAll { $0.ideaID == id && $0.state == .planned }
            for i in $0.nudges.indices where $0.nudges[i].ideaID == id { $0.nudges[i].ideaID = nil }
        }
    }

    func idea(_ id: UUID?) -> Idea? {
        guard let id else { return nil }
        return state.ideas.first { $0.id == id }
    }

    // MARK: - Blocks

    func checkIn(_ blockID: UUID, built: Bool) {
        guard let index = state.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let block = state.blocks[index]
        mutate {
            $0.blocks[index].state = built ? .done : .skipped
            if built, let i = $0.ideas.firstIndex(where: { $0.id == block.ideaID }) {
                // Credit only the time that has actually elapsed for a block finished early.
                let worked = min(block.minutes, max(0, Int(Date.now.timeIntervalSince(block.start) / 60)))
                $0.ideas[i].credit(minutes: block.end <= .now ? block.minutes : max(15, worked))
            }
        }
        let title = idea(block.ideaID)?.title ?? "idea"
        show(built ? "Logged \(BossFormat.hours(minutes: block.minutes)) on \(title)"
                   : "Skipped — the Boss re-planned \(title)")
    }

    func setLocked(_ blockID: UUID, _ locked: Bool) {
        mutate {
            if let i = $0.blocks.firstIndex(where: { $0.id == blockID }) { $0.blocks[i].locked = locked }
        }
    }

    /// Moves a block by whole minutes. Returns a reason when the move is refused. Moved blocks lock in place.
    func move(_ blockID: UUID, byMinutes delta: Int) -> String? {
        guard let index = state.blocks.firstIndex(where: { $0.id == blockID }) else { return "Block not found" }
        var block = state.blocks[index]
        let shift = TimeInterval(delta * 60)
        block.start += shift
        block.end += shift
        if block.start < TimeMath.roundUpToQuarter(now) - 15 * 60 { return "Can't move a block into the past" }
        if busyEvents.contains(where: { TimeMath.overlaps($0.interval, block.interval) }) && state.settings.useAppleCalendar {
            return "That collides with a calendar event"
        }
        if state.blocks.contains(where: { $0.id != block.id && $0.state != .skipped && TimeMath.overlaps($0.interval, block.interval) }) {
            return "That overlaps another block"
        }
        block.locked = true
        mutate { $0.blocks[index] = block }
        return nil
    }

    func block(_ id: UUID?) -> Block? {
        guard let id else { return nil }
        return state.blocks.first { $0.id == id }
    }

    // MARK: - Nudges

    func addNudge(title: String, due: Date, ideaID: UUID? = nil) {
        mutate(replan: false) { $0.nudges.append(Nudge(title: title, due: due, ideaID: ideaID)) }
        scheduleNotifications()
        show("Nudge set · \(Fmt.departure(due))")
    }

    func updateNudge(_ nudge: Nudge) {
        mutate(replan: false) {
            if let i = $0.nudges.firstIndex(where: { $0.id == nudge.id }) { $0.nudges[i] = nudge }
        }
        scheduleNotifications()
    }

    func toggleNudge(_ id: UUID) {
        mutate(replan: false) {
            if let i = $0.nudges.firstIndex(where: { $0.id == id }) { $0.nudges[i].done.toggle() }
        }
        scheduleNotifications()
    }

    func completeNudge(_ id: UUID) {
        mutate(replan: false) {
            if let i = $0.nudges.firstIndex(where: { $0.id == id }) { $0.nudges[i].done = true }
        }
        scheduleNotifications()
    }

    func snoozeNudge(_ id: UUID, minutes: Int = 15) {
        mutate(replan: false) {
            if let i = $0.nudges.firstIndex(where: { $0.id == id }) {
                $0.nudges[i].due = max(Date.now, $0.nudges[i].due).addingTimeInterval(TimeInterval(minutes * 60))
                $0.nudges[i].done = false
            }
        }
        scheduleNotifications()
    }

    func deleteNudge(_ id: UUID) {
        mutate(replan: false) { $0.nudges.removeAll { $0.id == id } }
        scheduleNotifications()
    }

    // MARK: - Settings & data

    func updateSettings(_ change: (inout PlannerSettings) -> Void) {
        mutate { change(&$0.settings) }
        if state.settings.useAppleCalendar { Task { await refresh() } }
    }

    func updateWindows(_ change: (inout [BuildWindow]) -> Void) {
        mutate { change(&$0.windows) }
    }

    func loadDemo() {
        let settings = state.settings
        state = Seed.state()
        state.settings = settings
        replan(announce: false)
        show("Loaded the demo pipeline")
    }

    func startEmpty() {
        let settings = state.settings, windows = state.windows
        state = BossState()
        state.settings = settings
        state.windows = windows
        replan(announce: false)
        show("Fresh start — jot your first idea")
    }

    // MARK: - Demo calendar (simulator screenshots: -demoBusy)

    private static func demoEvents(now: Date, calendar: Calendar) -> [BusyEvent] {
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Double, _ length: Double, _ title: String) -> BusyEvent {
            let start = calendar.date(byAdding: .minute, value: Int(hour * 60),
                                      to: calendar.date(byAdding: .day, value: day, to: today)!)!
            return BusyEvent(title: title, start: start, end: start.addingTimeInterval(length * 3600))
        }
        var events: [BusyEvent] = []
        for day in 0..<21 {
            let weekday = calendar.component(.weekday, from: calendar.date(byAdding: .day, value: day, to: today)!)
            if (2...6).contains(weekday) { events.append(at(day, 9, 8.5, "Work")) }
            if weekday == 4 { events.append(at(day, 19, 1.5, "Climbing")) }
            if weekday == 7 { events.append(at(day, 12.5, 1.5, "Lunch with Sam")) }
        }
        events.append(at(0, 18, 0.75, "Groceries"))
        return events
    }
}

extension JSONEncoder {
    static var boss: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var boss: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
