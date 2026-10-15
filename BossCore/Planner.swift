import Foundation

// Autopilot: turns queued ideas into build blocks. Pure, deterministic, explainable.
// Blueprint §3 is the contract; Tools/plannercheck and BossCoreTests hold it to its invariants.

public struct PlanInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var ideas: [Idea]
    public var blocks: [Block]
    public var windows: [BuildWindow]
    public var busy: [DateInterval]
    public var settings: PlannerSettings

    public init(now: Date, calendar: Calendar, ideas: [Idea], blocks: [Block], windows: [BuildWindow],
                busy: [DateInterval], settings: PlannerSettings) {
        self.now = now
        self.calendar = calendar
        self.ideas = ideas
        self.blocks = blocks
        self.windows = windows
        self.busy = busy
        self.settings = settings
    }
}

public struct Forecast: Sendable, Hashable {
    public var ideaID: UUID
    /// Projected finish. `estimated` is true when it lies beyond the planning horizon (extrapolated from the budget).
    public var finish: Date?
    public var estimated: Bool
    public var nextBlock: Date?
    public var scheduledMinutes: Int
}

public enum PlanWarning: Sendable, Hashable {
    case noWindows
    case deadlineAtRisk(UUID)
    case starved(UUID)
}

public struct PlanDiff: Sendable, Hashable {
    public var added = 0
    public var moved = 0
    public var removed = 0
    public var unchanged = 0

    public var summary: String {
        if added == 0 && moved == 0 && removed == 0 { return "Plan unchanged" }
        var parts: [String] = []
        if moved > 0 { parts.append("moved \(moved)") }
        if added > 0 { parts.append("added \(added)") }
        if removed > 0 { parts.append("dropped \(removed)") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + (added + moved + removed == 1 ? " block" : " blocks")
    }
}

public struct PlanOutput: Sendable {
    /// The complete block list: kept blocks plus newly planned ones, sorted by start.
    public var blocks: [Block]
    public var forecasts: [UUID: Forecast]
    public var warnings: [PlanWarning]
    public var diff: PlanDiff
}

public enum Planner {
    public static func plan(_ input: PlanInput) -> PlanOutput {
        let cal = input.calendar
        let s = input.settings
        let now = input.now
        let ideasByID = Dictionary(uniqueKeysWithValues: input.ideas.map { ($0.id, $0) })
        let queued = input.ideas.filter { $0.track == .queued }
        let busy = TimeMath.merge(input.busy)
        let freezeEnd = now.addingTimeInterval(TimeInterval(s.freezeHours * 3600))

        // Minutes each queued idea still needs scheduled, before any kept block reserves them.
        var need: [UUID: Int] = [:]
        for idea in queued { need[idea.id] = idea.remainingMinutes }

        // Step 1: keep what must not move.
        var kept: [Block] = []
        var discarded: [Block] = []
        for block in input.blocks.sorted(by: blockOrder) {
            let started = block.start <= now
            if block.state != .planned || block.locked || started {
                kept.append(block)
                // A locked or running block reserves its idea's time; finished/skipped/past ones don't.
                if block.state == .planned && block.end > now {
                    let future = block.start > now ? block.minutes
                        : Int((block.end.timeIntervalSince(now) / 60).rounded())
                    need[block.ideaID] = max(0, (need[block.ideaID] ?? 0) - future)
                }
                continue
            }
            let collides = busy.contains { TimeMath.overlaps($0, block.interval) }
            let stillNeeded = (need[block.ideaID] ?? 0) > 0 && ideasByID[block.ideaID]?.track == .queued
            if block.start < freezeEnd && !collides && stillNeeded {
                kept.append(block)
                need[block.ideaID] = max(0, (need[block.ideaID] ?? 0) - block.minutes)
            } else {
                discarded.append(block)
            }
        }

        // Capacity already held by kept blocks (skipped time doesn't count against you).
        var weekUsed: [Int: Int] = [:]
        var dayCount: [Date: Int] = [:]
        var weekIdeas: [Int: Set<UUID>] = [:]
        for block in kept where block.state != .skipped {
            let week = TimeMath.weekKey(block.start, calendar: cal)
            weekUsed[week, default: 0] += block.minutes
            dayCount[TimeMath.dayKey(block.start, calendar: cal), default: 0] += 1
            weekIdeas[week, default: []].insert(block.ideaID)
        }

        // Step 2: free time inside build windows.
        let free = freeIntervals(input: input, busy: busy, kept: kept)

        // Position along each idea's phase list where the next new block begins.
        var cursor: [UUID: Int] = [:]
        for idea in queued {
            let reserved = idea.remainingMinutes - (need[idea.id] ?? 0)
            cursor[idea.id] = idea.doneMinutes + max(0, reserved)
        }

        // Steps 3–5: cut slots and assign greedily.
        var created: [Block] = []
        var lastIdea: UUID? = kept.filter { $0.start <= now && $0.state != .skipped }.last?.ideaID
        let budget = s.weeklyBudgetHours * 60
        let minBlock = max(15, s.minBlockMinutes)
        let blockLength = max(minBlock, s.blockMinutes)

        for interval in free {
            var t = interval.start
            while true {
                // Floor, never round: a block may not run even seconds past its free interval.
                let left = Int((max(t, interval.end).timeIntervalSince(t) / 60).rounded(.down))
                if left < 15 { break }
                let day = TimeMath.dayKey(t, calendar: cal)
                let week = TimeMath.weekKey(t, calendar: cal)
                if dayCount[day, default: 0] >= s.maxBlocksPerDay { break }
                // Whole quarter hours keep every block edge on the board's 15-minute grid.
                let available = min(left, blockLength, budget - weekUsed[week, default: 0]) / 15 * 15
                if available < 15 { break }

                let open = queued.filter { (need[$0.id] ?? 0) > 0 }
                if open.isEmpty { break }
                let active = (weekIdeas[week] ?? []).filter { (need[$0] ?? 0) > 0 }
                let pool = active.count >= max(1, s.focusLimit) ? open.filter { active.contains($0.id) } : open

                let candidates = pool.filter { idea in
                    let full = TimeMath.roundUpToQuarter(minutes: need[idea.id] ?? 0)
                    // Short leftovers only take a block that finishes the idea.
                    if available < minBlock && full > available { return false }
                    let length = min(available, full)
                    if let deadline = idea.deadline, t.addingTimeInterval(TimeInterval(length * 60)) > deadline {
                        return false
                    }
                    return true
                }
                guard let pick = candidates.max(by: { a, b in
                    let sa = score(a, at: t, need: need[a.id] ?? 0, slot: available, last: lastIdea,
                                   free: free, now: now)
                    let sb = score(b, at: t, need: need[b.id] ?? 0, slot: available, last: lastIdea,
                                   free: free, now: now)
                    if sa != sb { return sa < sb }
                    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                    return a.id.uuidString > b.id.uuidString
                }) else {
                    // Nothing fits this slot (deadlines/size); try the next quarter hour.
                    t = t.addingTimeInterval(15 * 60)
                    continue
                }

                let length = min(available, TimeMath.roundUpToQuarter(minutes: need[pick.id] ?? 0))
                let end = t.addingTimeInterval(TimeInterval(length * 60))
                let position = cursor[pick.id] ?? 0
                created.append(Block(ideaID: pick.id, phaseTitle: phaseTitle(pick, from: position, minutes: length),
                                     start: t, end: end))
                need[pick.id] = max(0, (need[pick.id] ?? 0) - length)
                cursor[pick.id] = position + length
                weekUsed[week, default: 0] += length
                dayCount[day, default: 0] += 1
                weekIdeas[week, default: []].insert(pick.id)
                lastIdea = pick.id
                t = end.addingTimeInterval(TimeInterval(s.breakMinutes * 60))
            }
        }

        // Identity reuse keeps notification IDs stable and makes re-planning idempotent.
        var diff = PlanDiff()
        diff.unchanged = kept.filter { $0.state == .planned && $0.start > now }.count
        var pool = discarded
        for index in created.indices {
            let block = created[index]
            if let same = pool.firstIndex(where: { $0.ideaID == block.ideaID && $0.start == block.start && $0.end == block.end }) {
                created[index].id = pool[same].id
                created[index].phaseTitle = block.phaseTitle
                pool.remove(at: same)
                diff.unchanged += 1
            } else if let moved = pool.firstIndex(where: { $0.ideaID == block.ideaID }) {
                created[index].id = pool[moved].id
                pool.remove(at: moved)
                diff.moved += 1
            } else {
                diff.added += 1
            }
        }
        diff.removed = pool.count

        let all = (kept + created).sorted(by: blockOrder)
        return PlanOutput(blocks: all,
                          forecasts: forecasts(queued: queued, blocks: all, need: need, input: input),
                          warnings: warnings(queued: queued, blocks: all, input: input),
                          diff: diff)
    }

    // MARK: - Free time

    static func freeIntervals(input: PlanInput, busy: [DateInterval], kept: [Block]) -> [DateInterval] {
        let cal = input.calendar
        let s = input.settings
        let earliest = TimeMath.roundUpToQuarter(input.now)
        let today = cal.startOfDay(for: input.now)
        var windows: [DateInterval] = []
        for offset in 0..<max(1, s.horizonDays) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            for window in input.windows where window.weekday == weekday && window.minutes > 0 {
                let start = max(earliest, TimeMath.date(day, minuteOfDay: window.startMinute, calendar: cal))
                let end = TimeMath.date(day, minuteOfDay: window.endMinute, calendar: cal)
                if end > start { windows.append(DateInterval(start: start, end: end)) }
            }
        }
        let cuts = busy.map { TimeMath.pad($0, minutes: s.busyBufferMinutes) }
            + kept.filter { $0.state != .skipped }.map { TimeMath.pad($0.interval, minutes: s.breakMinutes) }
        // Snap starts to the quarter hour so blocks read cleanly on the board.
        return TimeMath.subtract(windows, cuts).compactMap { piece in
            let start = TimeMath.roundUpToQuarter(piece.start)
            return start < piece.end ? DateInterval(start: start, end: piece.end) : nil
        }
    }

    // MARK: - Scoring

    static func score(_ idea: Idea, at t: Date, need: Int, slot: Int, last: UUID?,
                      free: [DateInterval], now: Date) -> Double {
        var score = 12.0 * Double(idea.heat)
        let waitingDays = max(0, now.timeIntervalSince(idea.createdAt) / 86_400)
        score += min(10, 0.5 * waitingDays)
        if idea.id == last { score += 8 }
        if need <= slot { score += 6 }
        if let deadline = idea.deadline {
            let workLeft = free.reduce(0) { total, piece in
                let start = max(piece.start, t)
                let end = min(piece.end, deadline)
                return end > start ? total + TimeMath.minutes(DateInterval(start: start, end: end)) : total
            }
            score += 60 * min(2, max(0, Double(need) / Double(max(1, workLeft))))
        }
        return score
    }

    static func phaseTitle(_ idea: Idea, from position: Int, minutes: Int) -> String {
        var cumulative = 0
        for (index, phase) in idea.phases.enumerated() {
            let end = cumulative + phase.plannedMinutes
            if position < end {
                let spills = position + minutes > end && index < idea.phases.count - 1
                return phase.title + (spills ? "+" : "")
            }
            cumulative = end
        }
        return idea.phases.last?.title ?? "Build"
    }

    static func blockOrder(_ a: Block, _ b: Block) -> Bool {
        a.start != b.start ? a.start < b.start : a.id.uuidString < b.id.uuidString
    }

    // MARK: - Forecasts and warnings

    static func forecasts(queued: [Idea], blocks: [Block], need: [UUID: Int], input: PlanInput) -> [UUID: Forecast] {
        let s = input.settings
        let horizonEnd = input.calendar.date(byAdding: .day, value: s.horizonDays,
                                             to: input.calendar.startOfDay(for: input.now)) ?? input.now
        let sharers = Double(max(1, min(s.focusLimit, queued.count)))
        let perIdeaPerWeek = max(1, Double(s.weeklyBudgetHours * 60) / sharers)
        var out: [UUID: Forecast] = [:]
        for idea in queued {
            let mine = blocks.filter { $0.ideaID == idea.id && $0.state == .planned && $0.end > input.now }
            let scheduled = mine.reduce(0) { $0 + $1.minutes }
            let unplaced = need[idea.id] ?? 0
            var finish: Date? = mine.last?.end
            var estimated = false
            if idea.remainingMinutes == 0 {
                finish = nil
            } else if unplaced > 0 {
                finish = horizonEnd.addingTimeInterval(Double(unplaced) / perIdeaPerWeek * 7 * 86_400)
                estimated = true
            }
            out[idea.id] = Forecast(ideaID: idea.id, finish: finish, estimated: estimated,
                                    nextBlock: mine.first { $0.start > input.now }?.start ?? mine.first?.start,
                                    scheduledMinutes: scheduled)
        }
        return out
    }

    static func warnings(queued: [Idea], blocks: [Block], input: PlanInput) -> [PlanWarning] {
        var out: [PlanWarning] = []
        if input.windows.allSatisfy({ $0.minutes == 0 }) { out.append(.noWindows) }
        for idea in queued where idea.remainingMinutes > 0 {
            let mine = blocks.filter { $0.ideaID == idea.id && $0.state == .planned && $0.end > input.now }
            if mine.isEmpty { out.append(.starved(idea.id)) }
            if let deadline = idea.deadline {
                let before = mine.filter { $0.end <= deadline }.reduce(0) { $0 + $1.minutes }
                if before < idea.remainingMinutes { out.append(.deadlineAtRisk(idea.id)) }
            }
        }
        return out
    }
}
