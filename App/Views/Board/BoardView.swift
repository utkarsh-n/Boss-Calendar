import BossCore
import SwiftUI

/// Board: the week as a departures board — day tiles plus a timeline of busy time, windows, blocks and nudges.
struct BoardView: View {
    @Environment(BossStore.self) private var store
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var selected: BlockRef?

    private let hourHeight: CGFloat = 56
    private var cal: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Board", subtitle: subtitle) {
                InstrumentGlassIconButton("arrow.triangle.2.circlepath", label: "Re-plan now") {
                    store.replan(announce: true)
                }
                InstrumentGlassIconButton("calendar.badge.clock", label: "Today") {
                    withAnimation(.snappy) { selectedDay = cal.startOfDay(for: store.now) }
                }
            }
            dayStrip
            timeline
        }
        .background { InstrumentDesignBackground() }
        .sheet(item: $selected) { ref in BlockSheet(blockID: ref.id) }
    }

    private var subtitle: String {
        let blocks = store.state.blocks.filter { $0.state != .skipped && cal.isDate($0.start, inSameDayAs: selectedDay) }
        let minutes = blocks.reduce(0) { $0 + $1.minutes }
        return selectedDay.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).uppercased()
            + " · \(BossFormat.hours(minutes: minutes).uppercased()) BUILD"
    }

    // MARK: Day strip (Metro beat-tile grammar)

    private var days: [Date] {
        let today = cal.startOfDay(for: store.now)
        return (0..<min(28, store.state.settings.horizonDays)).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(days, id: \.self) { day in
                    DayTile(day: day, booked: booked(on: day), capacity: capacity(on: day),
                            selected: cal.isDate(day, inSameDayAs: selectedDay), today: cal.isDateInToday(day)) {
                        withAnimation(.snappy) { selectedDay = day }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 8)
    }

    private func booked(on day: Date) -> Int {
        store.state.blocks.filter { $0.state != .skipped && cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes }
    }

    private func capacity(on day: Date) -> Int {
        let weekday = cal.component(.weekday, from: day)
        return store.state.windows.filter { $0.weekday == weekday }.reduce(0) { $0 + $1.minutes }
    }

    // MARK: Timeline

    private var range: ClosedRange<Int> {
        let weekday = cal.component(.weekday, from: selectedDay)
        var first = 7
        for w in store.state.windows where w.weekday == weekday { first = min(first, w.startMinute / 60) }
        for b in blocksToday { first = min(first, cal.component(.hour, from: b.start)) }
        return max(0, first - 1)...24
    }

    private var blocksToday: [Block] {
        store.state.blocks.filter { cal.isDate($0.start, inSameDayAs: selectedDay) }
    }

    private func y(_ date: Date) -> CGFloat {
        let minutes = date.timeIntervalSince(cal.startOfDay(for: selectedDay)) / 60
        return CGFloat(minutes / 60 - Double(range.lowerBound)) * hourHeight
    }

    private var timeline: some View {
        let height = CGFloat(range.upperBound - range.lowerBound) * hourHeight
        let dayStart = cal.startOfDay(for: selectedDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let weekday = cal.component(.weekday, from: selectedDay)
        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Hour grid.
                    ForEach(Array(range), id: \.self) { hour in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", hour % 24))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 26, alignment: .trailing)
                            Rectangle().fill(.white.opacity(hour % 3 == 0 ? 0.09 : 0.045)).frame(height: 0.6)
                        }
                        .offset(y: CGFloat(hour - range.lowerBound) * hourHeight - 7)
                        .id(hour)
                        .accessibilityHidden(true)
                    }
                    // Build windows: faint cyan wash.
                    ForEach(store.state.windows.filter { $0.weekday == weekday }) { w in
                        let top = CGFloat(Double(w.startMinute) / 60 - Double(range.lowerBound)) * hourHeight
                        RoundedRectangle(cornerRadius: 10)
                            .fill(BossPalette.build.opacity(0.045))
                            .overlay(alignment: .topTrailing) {
                                Text("WINDOW").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.2)
                                    .foregroundStyle(BossPalette.build.opacity(0.45)).padding(6)
                            }
                            .frame(height: CGFloat(w.minutes) / 60 * hourHeight)
                            .padding(.leading, 40)
                            .offset(y: top)
                            .accessibilityHidden(true)
                    }
                    // Busy time from Apple Calendar.
                    ForEach(store.busyEvents.filter { $0.end > dayStart && $0.start < dayEnd }) { e in
                        let top = max(0, y(max(e.start, dayStart)))
                        let bottom = y(min(e.end, dayEnd))
                        BusySlab(event: e)
                            .frame(height: max(18, bottom - top - 2))
                            .padding(.leading, 40)
                            .offset(y: top + 1)
                    }
                    // Build blocks.
                    ForEach(blocksToday) { b in
                        let top = y(b.start)
                        Button { selected = BlockRef(id: b.id) } label: {
                            BlockSlab(block: b, title: store.idea(b.ideaID)?.title ?? "Idea", now: store.now)
                                .frame(height: max(30, y(b.end) - top - 2))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 40)
                        .offset(y: top + 1)
                    }
                    // Nudges: amber ticks.
                    ForEach(store.state.nudges.filter { !$0.done && cal.isDate($0.due, inSameDayAs: selectedDay) }) { n in
                        HStack(spacing: 6) {
                            Capsule().fill(BossPalette.now).frame(width: 10, height: 3)
                            Text(n.title).font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(BossPalette.now).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BossPalette.plot.opacity(0.9), in: .capsule)
                        }
                        .padding(.leading, 30)
                        .offset(y: y(n.due) - 8)
                        .accessibilityLabel("Nudge: \(n.title) at \(Fmt.time(n.due))")
                    }
                    // Now line.
                    if cal.isDate(store.now, inSameDayAs: selectedDay) {
                        HStack(spacing: 0) {
                            Circle().fill(BossPalette.now).frame(width: 7, height: 7)
                            Rectangle().fill(BossPalette.now).frame(height: 1.2)
                        }
                        .padding(.leading, 33)
                        .offset(y: y(store.now) - 3.5)
                        .accessibilityLabel("Now, \(Fmt.time(store.now))")
                    }
                }
                .frame(height: height + 20, alignment: .top)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollToFocus(proxy) }
            .onChange(of: selectedDay) { scrollToFocus(proxy) }
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        let target: Int
        if cal.isDate(store.now, inSameDayAs: selectedDay) {
            target = max(range.lowerBound, cal.component(.hour, from: store.now) - 1)
        } else if let first = blocksToday.first {
            target = max(range.lowerBound, cal.component(.hour, from: first.start) - 1)
        } else {
            target = range.lowerBound
        }
        withAnimation(.snappy) { proxy.scrollTo(min(target, 18), anchor: .top) }
    }
}

struct DayTile: View {
    let day: Date
    let booked: Int
    let capacity: Int
    let selected: Bool
    let today: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(today ? BossPalette.now : BossPalette.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? BossPalette.build : BossPalette.ink)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(BossPalette.build)
                            .frame(width: capacity == 0 ? 0 : geo.size.width * min(1, CGFloat(booked) / CGFloat(capacity)))
                    }
                }
                .frame(height: 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(width: 52)
            .background(selected ? BossPalette.build.opacity(0.08) : .white.opacity(0.025), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? BossPalette.build.opacity(0.35) : .white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue("\(BossFormat.spokenDuration(minutes: booked)) booked")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BusySlab: View {
    let event: BusyEvent
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(BossPalette.busy).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(BossPalette.ink.opacity(0.8)).lineLimit(1)
                Text("BUSY · \(Fmt.time(event.start))–\(Fmt.time(event.end))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(BossPalette.busy.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BossPalette.busy.opacity(0.07), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct BlockSlab: View {
    let block: Block
    let title: String
    let now: Date

    var body: some View {
        let running = block.state == .planned && block.start <= now && block.end > now
        let done = block.state == .done
        let skipped = block.state == .skipped
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(skipped ? BossPalette.secondary : BossPalette.ink)
                    .strikethrough(skipped)
                    .lineLimit(1)
                Text("\(block.phaseTitle) · \(Fmt.time(block.start))–\(Fmt.time(block.end))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(BossPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if block.locked { Image(systemName: "lock.fill") }
                if done { Image(systemName: "checkmark") }
                if running { Text("NOW").font(.system(size: 9, weight: .bold, design: .monospaced)) }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(running ? BossPalette.now : BossPalette.build)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(done ? BossPalette.build.opacity(0.16) : BossPalette.panel.opacity(0.95), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(running ? BossPalette.now.opacity(0.8) : BossPalette.build.opacity(skipped ? 0.12 : 0.45),
                              lineWidth: running ? 1.4 : 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the block")
    }
}
