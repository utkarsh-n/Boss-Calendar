import BossCore
import SwiftUI

struct BlockRef: Identifiable, Hashable { let id: UUID }

/// Station: today's instrument, the one budget knob, check-ins and departures.
struct StationView: View {
    @Environment(BossStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var tilt = TiltService()
    @State private var selected: BlockRef?
    @State private var showSettings = false
    @State private var budgetFeedback = 0

    private var cal: Calendar { .current }
    private var now: Date { store.now }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ScreenHeader(title: "Boss Calendar", subtitle: "STATION · " + now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()) {
                    InstrumentGlassIconButton("arrow.triangle.2.circlepath", label: "Re-plan now") {
                        store.replan(announce: true)
                    }
                    InstrumentGlassIconButton("gearshape", label: "Settings") { showSettings = true }
                }
                cluster
                budgetStepper
                telemetry
                if !pendingCheckIns.isEmpty { checkInPanel }
                if !bossNotes.isEmpty { notesPanel }
                departuresPanel
                if !dueNudges.isEmpty { nudgesPanel }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background { InstrumentDesignBackground() }
        .sheet(item: $selected) { ref in BlockSheet(blockID: ref.id) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { updateMotion() }
        .onDisappear { tilt.stop() }
        .onChange(of: scenePhase) { updateMotion() }
        .onChange(of: reduceMotion) { updateMotion() }
        .sensoryFeedback(.selection, trigger: budgetFeedback)
    }

    private func updateMotion() {
        if scenePhase == .active && !reduceMotion { tilt.start() } else { tilt.stop() }
    }

    // MARK: - Derived state

    private var todays: [Block] {
        store.state.blocks.filter { cal.isDate($0.start, inSameDayAs: now) }
    }
    private var current: Block? {
        store.state.blocks.first { $0.state == .planned && $0.start <= now && $0.end > now }
    }
    private var upcoming: [Block] {
        store.state.blocks.filter { $0.state == .planned && $0.start > now }
    }
    private var pendingCheckIns: [Block] {
        store.state.blocks
            .filter { $0.state == .planned && $0.end <= now && $0.end > now.addingTimeInterval(-7 * 86_400) }
            .sorted { $0.start > $1.start }
            .prefix(3).map { $0 }
    }
    private var dueNudges: [Nudge] {
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        return store.state.nudges.filter { !$0.done && $0.due < endOfToday }.sorted { $0.due < $1.due }
    }
    private var queued: [Idea] { store.state.ideas.filter { $0.track == .queued } }
    private var queuedMinutes: Int { queued.reduce(0) { $0 + $1.remainingMinutes } }

    private func title(_ block: Block) -> String {
        store.idea(block.ideaID)?.title ?? "Idea"
    }

    private var snapshot: DaySnapshot {
        let start = cal.startOfDay(for: now)
        func minute(_ d: Date) -> Double { min(1440, max(0, d.timeIntervalSince(start) / 60)) }
        var arcs: [DaySnapshot.Arc] = []
        let weekday = cal.component(.weekday, from: now)
        for w in store.state.windows where w.weekday == weekday {
            arcs.append(.init(startMinute: Double(w.startMinute), endMinute: Double(w.endMinute), kind: .window))
        }
        for e in store.busyEvents where e.end > start && e.start < start.addingTimeInterval(86_400) {
            arcs.append(.init(startMinute: minute(e.start), endMinute: minute(e.end), kind: .busy))
        }
        let focus = current ?? upcoming.first
        for b in todays {
            let kind: DaySnapshot.Arc.Kind = switch b.state {
            case .done: .done
            case .skipped: .skipped
            case .planned: b.id == focus?.id ? .highlighted : .planned
            }
            arcs.append(.init(startMinute: minute(b.start), endMinute: minute(b.end), kind: kind))
        }

        let todayPlanned = todays.filter { $0.state != .skipped }
        let todayMinutes = todayPlanned.reduce(0) { $0 + $1.minutes }
        var metadata = "\(todayPlanned.count) BLOCK\(todayPlanned.count == 1 ? "" : "S") TODAY · \(BossFormat.hours(minutes: todayMinutes).uppercased())"
        let value: String, unit: String, meaning: String?, spoken: String
        if let b = current {
            let left = Int(ceil(b.end.timeIntervalSince(now) / 60))
            value = BossFormat.clock(minutes: left)
            unit = "LEFT IN BLOCK"
            meaning = "\(title(b)) · \(b.phaseTitle)"
            if let i = todayPlanned.firstIndex(of: b) { metadata = "BLOCK \(i + 1) OF \(todayPlanned.count) · ENDS \(Fmt.time(b.end))" }
            spoken = "Building \(title(b)), \(b.phaseTitle). \(BossFormat.spokenDuration(minutes: left)) left."
        } else if let b = upcoming.first {
            let until = Int(ceil(b.start.timeIntervalSince(now) / 60))
            if cal.isDate(b.start, inSameDayAs: now) || until < 12 * 60 {
                value = BossFormat.clock(minutes: until)
                unit = "UNTIL NEXT BLOCK"
            } else {
                value = b.start.formatted(.dateTime.weekday(.abbreviated))
                unit = "NEXT BLOCK \(Fmt.time(b.start))"
            }
            meaning = "\(title(b)) · \(b.phaseTitle)"
            spoken = "Next block: \(title(b)), \(b.phaseTitle), \(Fmt.departure(b.start)). \(todayPlanned.count) blocks today."
        } else {
            value = "0"
            unit = "BLOCKS BOOKED"
            meaning = queued.isEmpty ? "Jot an idea" : "Add build windows"
            spoken = "No build blocks booked."
        }
        return DaySnapshot(nowMinute: minute(now), arcs: arcs, value: value, unit: unit, meaning: meaning,
                           metadata: metadata, spoken: spoken)
    }

    // MARK: - Instrument cluster

    private var cluster: some View {
        GeometryReader { geo in
            let clusterWidth = min(geo.size.width, 490)
            let pillWidth: CGFloat = clusterWidth < 350 ? 30 : 36
            let d = min(360, clusterWidth - 2 * pillWidth - 12)
            let pillHeight = min(218, 0.66 * d)
            HStack(spacing: 6) {
                loadPill(width: pillWidth, height: pillHeight)
                DayDial(snapshot: snapshot, tilt: tilt.vector, motionActive: tilt.isActive)
                    .frame(width: d, height: d)
                queuePill(width: pillWidth, height: pillHeight)
            }
            .frame(width: geo.size.width)
        }
        .aspectRatio(1.28, contentMode: .fit)
        .frame(maxWidth: 490)
    }

    private struct DayLoad { var day: Date; var booked: Int; var window: Int; var busy: Int }

    private var weekLoad: [DayLoad] {
        let monday = TimeMath.startOfWeek(now, calendar: cal)
        return (0..<7).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: monday) else { return nil }
            let weekday = cal.component(.weekday, from: day)
            let windows = store.state.windows.filter { $0.weekday == weekday }
            let windowMinutes = windows.reduce(0) { $0 + $1.minutes }
            let booked = store.state.blocks.filter { $0.state != .skipped && cal.isDate($0.start, inSameDayAs: day) }
                .reduce(0) { $0 + $1.minutes }
            let windowIntervals = windows.map {
                DateInterval(start: TimeMath.date(day, minuteOfDay: $0.startMinute, calendar: cal),
                             end: TimeMath.date(day, minuteOfDay: $0.endMinute, calendar: cal))
            }
            let busyInside = TimeMath.merge(store.busyEvents.map(\.interval)).reduce(0) { total, e in
                total + windowIntervals.reduce(0) { sum, w in
                    let s = max(e.start, w.start), t = min(e.end, w.end)
                    return t > s ? sum + TimeMath.minutes(DateInterval(start: s, end: t)) : sum
                }
            }
            return DayLoad(day: day, booked: booked, window: windowMinutes, busy: busyInside)
        }
    }

    private func loadPill(width: CGFloat, height: CGFloat) -> some View {
        let load = weekLoad
        let scale = Double(max(60, load.map { max($0.window, $0.booked) }.max() ?? 60))
        let spoken = load.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \(BossFormat.spokenDuration(minutes: $0.booked)) booked" }
            .joined(separator: ", ")
        return SignalPill(title: "LOAD", top: "M", bottom: "S", width: width, height: height,
                          accent: BossPalette.build, spoken: "Build hours this week, Monday at top. " + spoken) {
            Canvas { ctx, size in
                let row = size.height / 7
                for (i, d) in load.enumerated() {
                    let y = row * (CGFloat(i) + 0.5)
                    let full = size.width
                    // Quiet reference: the day's window length.
                    let windowW = full * CGFloat(Double(d.window) / scale)
                    ctx.fill(Path(roundedRect: CGRect(x: (full - windowW) / 2, y: y - 1, width: windowW, height: 2),
                                  cornerRadius: 1), with: .color(.white.opacity(0.10)))
                    let busyW = full * CGFloat(Double(d.busy) / scale)
                    if busyW > 0 {
                        ctx.fill(Path(roundedRect: CGRect(x: (full - busyW) / 2, y: y + 2.5, width: busyW, height: 1.5),
                                      cornerRadius: 0.75), with: .color(BossPalette.busy.opacity(0.75)))
                    }
                    let w = full * CGFloat(Double(d.booked) / scale)
                    if w > 0 {
                        ctx.fill(Path(roundedRect: CGRect(x: (full - w) / 2, y: y - 2.5, width: w, height: 5),
                                      cornerRadius: 2.5), with: .color(BossPalette.build.opacity(0.9)))
                    }
                    if cal.isDate(d.day, inSameDayAs: now) {
                        ctx.fill(Path(ellipseIn: CGRect(x: -1, y: y - 1.5, width: 3, height: 3)), with: .color(BossPalette.now))
                    }
                }
            }
        }
    }

    private func queuePill(width: CGFloat, height: CGFloat) -> some View {
        let top = queued.filter { $0.remainingMinutes > 0 }
            .sorted { ($0.heat, $0.remainingMinutes) > ($1.heat, $1.remainingMinutes) }
            .prefix(6)
        let total = max(1, top.reduce(0) { $0 + $1.remainingMinutes })
        let spoken = top.map { "\($0.title) \(BossFormat.spokenDuration(minutes: $0.remainingMinutes))" }.joined(separator: ", ")
        return SignalPill(title: "QUEUE", top: "\(Int((Double(queuedMinutes) / 60).rounded()))h", bottom: "0",
                          width: width, height: height, accent: BossPalette.build,
                          spoken: "Remaining hours of top queued ideas, hottest at the bottom. " + spoken) {
            Canvas { ctx, size in
                var y = size.height
                let gap: CGFloat = 2
                let usable = size.height - gap * CGFloat(max(0, top.count - 1))
                for (i, idea) in top.enumerated() {
                    let h = max(3, usable * CGFloat(Double(idea.remainingMinutes) / Double(total)))
                    let rect = CGRect(x: size.width * 0.18, y: y - h, width: size.width * 0.64, height: h)
                    let color = i.isMultiple(of: 2) ? BossPalette.build : InstrumentPalette.wave
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.85 - Double(i) * 0.1)))
                    y -= h + gap
                }
                // Reference rail.
                ctx.stroke(Path { p in p.move(to: CGPoint(x: size.width / 2, y: 0)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height)) },
                           with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Budget knob

    private var budgetStepper: some View {
        VStack(spacing: 6) {
            InstrumentParameterStepper("WEEKLY HOURS", value: Binding(
                get: { store.state.settings.weeklyBudgetHours },
                set: { value in store.updateSettings { $0.weeklyBudgetHours = value } }
            ), in: 1...60, unit: "h/wk", onAcceptedChange: { _ in budgetFeedback += 1 })
            .frame(maxWidth: 380)
            let weekBlocks = store.state.blocks.filter {
                $0.state != .skipped && TimeMath.weekKey($0.start, calendar: cal) == TimeMath.weekKey(now, calendar: cal)
            }
            HStack(spacing: 6) {
                Text(BossMeaning.budget(store.state.settings.weeklyBudgetHours))
                    .font(.system(.subheadline, design: .serif, weight: .medium))
                    .italic()
                    .foregroundStyle(BossPalette.build)
                Text("· \(weekBlocks.count) BLOCK\(weekBlocks.count == 1 ? "" : "S") BOOKED THIS WEEK")
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(BossPalette.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var telemetry: some View {
        let budget = max(1, store.state.settings.weeklyBudgetHours * 60)
        let weeks = Double(queuedMinutes) / Double(budget)
        return InstrumentContentPanel {
            HStack(spacing: 0) {
                InstrumentMetricReadout("IDEAS", value: "\(queued.count)", unit: "queued")
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                InstrumentMetricReadout("QUEUED", value: BossFormat.hoursValue(minutes: queuedMinutes), unit: "h")
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                InstrumentMetricReadout("CLEARS", value: weeks < 10 ? String(format: "%.1f", weeks) : "\(Int(weeks))",
                                        unit: "wk", color: BossPalette.now)
            }
        }
    }

    // MARK: - Panels

    private var checkInPanel: some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "CHECK IN", color: BossPalette.now, trailing: "\(pendingCheckIns.count) WAITING")
                ForEach(pendingCheckIns) { block in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Did you build \(title(block))?")
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(BossPalette.ink)
                        Text("\(block.phaseTitle) · \(Fmt.departure(block.start, now: now))–\(Fmt.time(block.end))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(BossPalette.secondary)
                        GlassEffectContainer(spacing: 10) {
                            HStack(spacing: 10) {
                                GlassActionButton(title: "Built it", symbol: "checkmark", prominent: true) {
                                    withAnimation(.snappy) { store.checkIn(block.id, built: true) }
                                }
                                GlassActionButton(title: "Skipped", symbol: "arrow.uturn.forward", accent: BossPalette.secondary) {
                                    withAnimation(.snappy) { store.checkIn(block.id, built: false) }
                                }
                            }
                        }
                    }
                    if block.id != pendingCheckIns.last?.id { Divider().overlay(.white.opacity(0.06)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sensoryFeedback(.success, trigger: pendingCheckIns.count)
    }

    private var bossNotes: [String] {
        store.warnings.compactMap { warning in
            switch warning {
            case .noWindows: return "No build windows yet — add some in Settings so the Boss can book time."
            case .deadlineAtRisk(let id):
                guard let idea = store.idea(id), let deadline = idea.deadline else { return nil }
                return "\(idea.title) won't make \(Fmt.shortDate(deadline)) — raise weekly hours, trim phases or move the deadline."
            case .starved(let id):
                guard let idea = store.idea(id) else { return nil }
                return "\(idea.title) has no block in the next \(store.state.settings.horizonDays) days (focus limit or budget)."
            }
        }
        .prefix(3).map { $0 }
    }

    private var notesPanel: some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "BOSS NOTES", color: BossPalette.now)
                ForEach(bossNotes, id: \.self) { note in
                    Label {
                        Text(note).font(.subheadline).foregroundStyle(BossPalette.ink.opacity(0.9))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(BossPalette.now)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var departuresPanel: some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "DEPARTURES", trailing: upcoming.isEmpty && current == nil ? nil : "NEXT \(min(6, upcoming.count + (current == nil ? 0 : 1)))")
                let rows = ([current].compactMap { $0 } + upcoming).prefix(6)
                if rows.isEmpty {
                    Text(queued.isEmpty ? "Nothing queued. Jot an idea below and the Boss will book it."
                                        : "No free build time found. Add build windows or raise weekly hours.")
                        .font(.subheadline)
                        .foregroundStyle(BossPalette.secondary)
                }
                ForEach(Array(rows)) { block in
                    Button { selected = BlockRef(id: block.id) } label: { DepartureRow(block: block, title: title(block), now: now) }
                        .buttonStyle(.plain)
                    if block.id != rows.last?.id { Divider().overlay(.white.opacity(0.06)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nudgesPanel: some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "NUDGES DUE", color: BossPalette.now, trailing: "TODAY")
                ForEach(dueNudges) { nudge in
                    NudgeRow(nudge: nudge, ideaTitle: store.idea(nudge.ideaID)?.title, now: now) {
                        withAnimation(.snappy) { store.toggleNudge(nudge.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Departures-board row: time · line · phase · status.
struct DepartureRow: View {
    let block: Block
    let title: String
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var status: (String, Color) {
        if block.state == .done { return ("DONE", BossPalette.build) }
        if block.state == .skipped { return ("SKIPPED", BossPalette.secondary) }
        if block.start <= now && block.end > now { return ("NOW", BossPalette.now) }
        if block.start.timeIntervalSince(now) <= 15 * 60 { return ("BOARDING", BossPalette.now) }
        return (block.locked ? "LOCKED" : "ON TIME", BossPalette.build.opacity(0.75))
    }

    var body: some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                     : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Text(Fmt.boardTime(block.start, now: now))
                .font(.system(.body, design: .monospaced, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BossPalette.ink)
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(BossPalette.ink)
                    .lineLimit(1)
                Text("\(block.phaseTitle) · \(BossFormat.hours(minutes: block.minutes))")
                    .font(.caption)
                    .foregroundStyle(BossPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if block.locked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                Text(status.0).font(.system(.caption2, design: .monospaced, weight: .semibold)).tracking(1.1)
            }
            .foregroundStyle(status.1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the block")
    }
}

struct NudgeRow: View {
    let nudge: Nudge
    let ideaTitle: String?
    let now: Date
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: nudge.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(nudge.done ? BossPalette.build : (nudge.due < now ? BossPalette.now : BossPalette.secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nudge.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(nudge.title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(nudge.done ? BossPalette.secondary : BossPalette.ink)
                    .strikethrough(nudge.done)
                HStack(spacing: 6) {
                    Text(Fmt.departure(nudge.due, now: now) + (nudge.due < now && !nudge.done ? " · OVERDUE" : ""))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(nudge.due < now && !nudge.done ? BossPalette.now : BossPalette.secondary)
                    if let ideaTitle {
                        Text("· \(ideaTitle)").font(.caption).foregroundStyle(BossPalette.build.opacity(0.8)).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
