import Foundation

// Randomised + scenario checks of Blueprint §3 invariants.
var failures = 0
var checks = 0
@MainActor func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("FAIL:", message()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 7))!

struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

@MainActor func verify(_ input: PlanInput, _ out: PlanOutput, label: String) {
    let s = input.settings
    let planned = out.blocks.filter { $0.state != .skipped }
    let sorted = planned.sorted { $0.start < $1.start }
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        check(a.end <= b.start, "\(label): overlap \(a.start)…\(a.end) with \(b.start)")
    }
    let fresh = out.blocks.filter { b in !input.blocks.contains { $0.id == b.id && $0.start == b.start && $0.end == b.end } }
    let windows = Planner.freeIntervals(input: input, busy: input.busy, kept: [])
    for b in fresh {
        check(!input.busy.contains { TimeMath.overlaps($0, b.interval) }, "\(label): block over busy at \(b.start)")
        check(windows.contains { $0.start <= b.start && b.end <= $0.end }, "\(label): block outside window \(b.start)")
        check(b.start >= input.now, "\(label): block in the past")
        check(b.minutes >= 15 && b.minutes <= max(s.blockMinutes, s.minBlockMinutes), "\(label): bad length \(b.minutes)")
        if let idea = input.ideas.first(where: { $0.id == b.ideaID }) {
            check(idea.track == .queued, "\(label): non-queued idea scheduled")
            if let d = idea.deadline { check(b.end <= d, "\(label): block after deadline") }
        }
    }
    var week: [Int: Int] = [:], day: [Date: Int] = [:], weekIdeas: [Int: Set<UUID>] = [:]
    for b in planned where b.end > input.now || b.state == .done {
        week[TimeMath.weekKey(b.start, calendar: input.calendar), default: 0] += b.minutes
        day[cal.startOfDay(for: b.start), default: 0] += 1
        weekIdeas[TimeMath.weekKey(b.start, calendar: input.calendar), default: []].insert(b.ideaID)
    }
    let keptWeek = Dictionary(grouping: input.blocks.filter { $0.state != .planned || $0.locked }, by: { TimeMath.weekKey($0.start, calendar: input.calendar) })
    for (k, v) in week where keptWeek[k] == nil {
        check(v <= s.weeklyBudgetHours * 60, "\(label): week \(k) \(v) min > budget")
    }
    for (_, v) in day { check(v <= max(s.maxBlocksPerDay, 1) || !input.blocks.isEmpty, "\(label): \(v) blocks in a day") }
    // Focus: ideas still being scheduled after a week ends (i.e. active at week end) never exceed the limit.
    let lastBlock = Dictionary(grouping: planned, by: \.ideaID).mapValues { $0.map(\.start).max()! }
    for (k, v) in weekIdeas where keptWeek[k] == nil && input.blocks.isEmpty {
        let continuing = v.filter { TimeMath.weekKey(lastBlock[$0]!, calendar: input.calendar) > k }
        check(continuing.count <= max(1, s.focusLimit), "\(label): week \(k) has \(continuing.count) active ideas")
    }
    for b in input.blocks where b.locked || b.state != .planned || b.start <= input.now {
        check(out.blocks.contains(b), "\(label): fixed block changed")
    }
    let per = Dictionary(grouping: fresh, by: \.ideaID)
    for (id, bs) in per {
        let idea = input.ideas.first { $0.id == id }!
        check(bs.reduce(0) { $0 + $1.minutes } <= TimeMath.roundUpToQuarter(minutes: idea.remainingMinutes) + 15 * bs.count,
              "\(label): over-scheduled \(idea.title)")
    }
}

// Scenario 1: seed data, no busy time.
var seed = Seed.state(now: base, calendar: cal)
var input = PlanInput(now: base, calendar: cal, ideas: seed.ideas, blocks: [], windows: seed.windows, busy: [], settings: seed.settings)
var out = Planner.plan(input)
verify(input, out, label: "seed")
check(!out.blocks.isEmpty, "seed produced no blocks")
print("seed: \(out.blocks.count) blocks, diff: \(out.diff.summary)")
let f = DateFormatter(); f.dateFormat = "EEE d HH:mm"; f.timeZone = cal.timeZone
for b in out.blocks.prefix(12) {
    print("  \(f.string(from: b.start))–\(f.string(from: b.end).suffix(5))  \(seed.idea(b.ideaID)!.title) · \(b.phaseTitle)")
}

// Scenario 2: idempotence.
input.blocks = out.blocks
let again = Planner.plan(input)
check(again.blocks == out.blocks, "re-plan not idempotent")
check(again.diff.added == 0 && again.diff.moved == 0 && again.diff.removed == 0, "re-plan diff not empty: \(again.diff)")

// Scenario 3: lock + budget change.
var locked = out.blocks
let lockIndex = locked.count / 2
locked[lockIndex].locked = true
input.blocks = locked
input.settings.weeklyBudgetHours = 4
let tight = Planner.plan(input)
check(tight.blocks.contains(locked[lockIndex]), "locked block moved")
verify(input, tight, label: "budget4")

// Scenario 4: busy event over a frozen block.
input.settings = seed.settings
input.blocks = out.blocks
if let first = out.blocks.first {
    input.busy = [DateInterval(start: first.start.addingTimeInterval(600), duration: 3600)]
    let moved = Planner.plan(input)
    check(!moved.blocks.contains { $0.id == first.id && $0.start == first.start }, "frozen block not moved off busy")
    verify(input, moved, label: "collision")
}

// Scenario 5: focus limit — first week has ≤ 2 ideas.
let firstWeek = TimeMath.weekKey(base, calendar: cal)
let ideasWeek1 = Set(out.blocks.filter { TimeMath.weekKey($0.start, calendar: cal) == firstWeek }.map(\.ideaID))
check(ideasWeek1.count <= 2, "focus limit broken: \(ideasWeek1.count)")

// Scenario 6: deadline idea gets priority.
let toothpaste = seed.ideas[2]
let tpBlocks = out.blocks.filter { $0.ideaID == toothpaste.id }
check(!tpBlocks.isEmpty, "deadline idea not scheduled")

// Scenario 7: randomized fuzz.
var rng = RNG(state: 42)
for run in 0..<400 {
    var s = PlannerSettings()
    s.weeklyBudgetHours = Int.random(in: 1...30, using: &rng)
    s.blockMinutes = [30, 45, 60, 90, 120, 180].randomElement(using: &rng)!
    s.minBlockMinutes = min(s.blockMinutes, [15, 30, 45].randomElement(using: &rng)!)
    s.maxBlocksPerDay = Int.random(in: 1...4, using: &rng)
    s.focusLimit = Int.random(in: 1...4, using: &rng)
    s.horizonDays = Int.random(in: 3...28, using: &rng)
    let now = base.addingTimeInterval(Double.random(in: 0...(7 * 86_400), using: &rng))
    var ideas: [Idea] = []
    for i in 0..<Int.random(in: 0...9, using: &rng) {
        var idea = Idea(title: "I\(i)", createdAt: now.addingTimeInterval(-Double.random(in: 0...2e6, using: &rng)),
                        track: [.queued, .queued, .queued, .note, .paused].randomElement(using: &rng)!,
                        heat: Int.random(in: 1...5, using: &rng),
                        deadline: Bool.random(using: &rng) ? now.addingTimeInterval(Double.random(in: 3600...2e6, using: &rng)) : nil,
                        phases: IdeaSize.allCases.randomElement(using: &rng)!.phases())
        idea.credit(minutes: Int.random(in: 0...600, using: &rng))
        ideas.append(idea)
    }
    var windows: [BuildWindow] = []
    for _ in 0..<Int.random(in: 0...10, using: &rng) {
        let a = Int.random(in: 0...(23 * 4), using: &rng) * 15
        windows.append(BuildWindow(weekday: Int.random(in: 1...7, using: &rng), startMinute: a,
                                   endMinute: min(1440, a + Int.random(in: 1...16, using: &rng) * 15)))
    }
    var busy: [DateInterval] = []
    for _ in 0..<Int.random(in: 0...20, using: &rng) {
        busy.append(DateInterval(start: now.addingTimeInterval(Double.random(in: -86_400...(20 * 86_400), using: &rng)),
                                 duration: Double.random(in: 900...14_400, using: &rng)))
    }
    var inp = PlanInput(now: now, calendar: cal, ideas: ideas, blocks: [], windows: windows, busy: busy, settings: s)
    let o = Planner.plan(inp)
    verify(inp, o, label: "fuzz\(run)")
    inp.blocks = o.blocks
    let o2 = Planner.plan(inp)
    if o2.blocks != o.blocks {
        check(false, "fuzz\(run): not idempotent")
        for (a, b) in zip(o.blocks, o2.blocks) where a != b { print("   ", a.start, a.end, a.minutes, "→", b.start, b.end, b.minutes, a.id == b.id) }
        print("    counts", o.blocks.count, o2.blocks.count)
    }
    // Advance time a day, mark some done/skipped, re-plan.
    var later = o.blocks
    for i in later.indices where later[i].start < now.addingTimeInterval(86_400) {
        later[i].state = Bool.random(using: &rng) ? .done : .skipped
    }
    inp.blocks = later
    inp.now = now.addingTimeInterval(86_400)
    verify(inp, Planner.plan(inp), label: "fuzz\(run)+1d")
}

// NaturalDate
if let m = NaturalDate.parse("call Sam tomorrow at 5pm", now: base) {
    check(m.title == "call Sam", "natural title: \(m.title)")
    check(Calendar.current.component(.hour, from: m.date) == 17, "natural hour")
} else { check(false, "natural date not found") }

// Sizing
for size in IdeaSize.allCases {
    check(size.phases().reduce(0) { $0 + $1.plannedMinutes } == size.hours * 60, "size \(size) sums wrong")
}

// Strict offline-shaping schema and compatibility with saved provider metadata.
func decodeShape(_ text: String) throws -> ShapedPlan {
    let plan = try JSONDecoder().decode(ShapedPlan.self, from: Data(text.utf8))
    try plan.validate()
    return plan
}
let validShape = #"{"summary":"Build a small offline notes app.","phases":[{"title":"Blueprint","hours":2},{"title":"Prototype","hours":6},{"title":"Ship","hours":1}]}"#
do {
    let plan = try decodeShape(validShape)
    check(plan.phases.map(\.hours) == [2, 6, 1], "shaped plan changed valid hour estimates")
    let roundTrip = try decodeShape(String(data: JSONEncoder().encode(plan), encoding: .utf8)!)
    check(roundTrip == plan,
          "shaped plan failed complete JSON round trip")
} catch { check(false, "valid shaped plan rejected: \(error)") }
let invalidShapes = [
    validShape.replacingOccurrences(of: "Build a small offline notes app.", with: ""),
    validShape.replacingOccurrences(of: "Build a small offline notes app.", with: #"Build\na notes app."#),
    validShape.replacingOccurrences(of: #",{"title":"Ship","hours":1}"#, with: ""),
    validShape.replacingOccurrences(of: #""Blueprint""#, with: #""Prototype""#),
    validShape.replacingOccurrences(of: #""Blueprint""#, with: #""""#),
    validShape.replacingOccurrences(of: #""Blueprint""#, with: #""A title with four words""#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""hours":0"#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""hours":41"#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""hours":true"#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""hours":"2""#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""hours":2,"extra":1"#),
    validShape.replacingOccurrences(of: #""hours":2"#, with: #""extra":2"#),
    validShape.replacingOccurrences(of: #""summary":"#, with: #""extra":1,"summary":"#),
    String(validShape.dropLast()),
    "```json\n" + validShape + "\n```",
    validShape + " trailing text",
]
for (index, invalid) in invalidShapes.enumerated() {
    do { _ = try decodeShape(invalid); check(false, "invalid shaped plan \(index) was accepted") }
    catch { check(true, "invalid shaped plan rejected") }
}
for source in [ShapeSource.template, .appleIntelligence, .manual, .qwen2B, .qwen4B] {
    do {
        let encoded = try JSONEncoder().encode(source)
        let decodedSource = try JSONDecoder().decode(ShapeSource.self, from: encoded)
        check(decodedSource == source,
              "shape source round trip failed: \(source)")
    } catch { check(false, "shape source round trip error: \(error)") }
}
do {
    let oldSource = try JSONDecoder().decode(ShapeSource.self, from: Data(#""appleIntelligence""#.utf8))
    check(oldSource == .appleIntelligence,
          "existing Apple Intelligence plan metadata no longer restores")
} catch { check(false, "old shape source rejected: \(error)") }

let t0 = Date()
var big = Seed.state(now: base, calendar: cal)
for i in 0..<300 { big.ideas.append(Idea(title: "B\(i)", heat: i % 5 + 1, phases: IdeaSize.l.phases())) }
big.settings.weeklyBudgetHours = 40
_ = Planner.plan(PlanInput(now: base, calendar: cal, ideas: big.ideas, blocks: [], windows: big.windows, busy: [], settings: big.settings))
print(String(format: "300-idea plan: %.1f ms", Date().timeIntervalSince(t0) * 1000))

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
