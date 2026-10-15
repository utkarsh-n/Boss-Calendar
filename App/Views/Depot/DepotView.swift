import BossCore
import SwiftUI

/// Depot: every idea and note, grouped by where it stands.
struct DepotView: View {
    @Environment(BossStore.self) private var store
    @State private var search = ""
    @State private var jot: JotKind?

    private var cal: Calendar { .current }

    private var filtered: [Idea] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.state.ideas }
        return store.state.ideas.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
    }

    private var sections: [(String, [Idea])] {
        let week = TimeMath.weekKey(store.now, calendar: cal)
        let boarding = Set(store.state.blocks.filter {
            $0.state == .planned && $0.end > store.now && TimeMath.weekKey($0.start, calendar: cal) == week
        }.map(\.ideaID))
        let ideas = filtered
        let byNext: (Idea, Idea) -> Bool = { a, b in
            let na = store.forecasts[a.id]?.nextBlock ?? .distantFuture
            let nb = store.forecasts[b.id]?.nextBlock ?? .distantFuture
            return na != nb ? na < nb : a.heat > b.heat
        }
        return [
            ("BOARDING THIS WEEK", ideas.filter { $0.track == .queued && boarding.contains($0.id) }.sorted(by: byNext)),
            ("QUEUED", ideas.filter { $0.track == .queued && !boarding.contains($0.id) }.sorted(by: byNext)),
            ("NOTES", ideas.filter { $0.track == .note }.sorted { $0.updatedAt > $1.updatedAt }),
            ("PAUSED", ideas.filter { $0.track == .paused }),
            ("SHIPPED", ideas.filter { $0.track == .shipped }.sorted { $0.updatedAt > $1.updatedAt })
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.state.ideas.isEmpty {
                    ContentUnavailableView("The depot is empty", systemImage: "tram",
                                           description: Text("Jot an idea and the Boss will find build time for it."))
                        .listRowBackground(Color.clear)
                }
                ForEach(sections, id: \.0) { section in
                    Section {
                        ForEach(section.1) { idea in
                            NavigationLink(value: idea.id) {
                                IdeaRow(idea: idea, forecast: store.forecasts[idea.id], now: store.now)
                            }
                            .bossRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteIdea(idea.id) } label: { Label("Delete", systemImage: "trash") }
                                if idea.track == .queued {
                                    Button { setTrack(idea, .paused) } label: { Label("Pause", systemImage: "pause") }.tint(.gray)
                                } else if idea.track != .shipped {
                                    Button { setTrack(idea, .queued) } label: { Label("Build", systemImage: "hammer") }.tint(BossPalette.build)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if idea.track == .queued {
                                    Button { setTrack(idea, .shipped) } label: { Label("Shipped", systemImage: "flag.checkered") }.tint(BossPalette.now)
                                }
                            }
                        }
                    } header: {
                        SectionLabel(text: section.0, color: section.0 == "BOARDING THIS WEEK" ? BossPalette.now : BossPalette.build,
                                     trailing: "\(section.1.count)")
                    }
                }
            }
            .bossListStyle()
            .navigationTitle("Depot")
            .navigationDestination(for: UUID.self) { IdeaDetailView(ideaID: $0) }
            .searchable(text: $search, prompt: "Search ideas and notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { jot = .idea } label: { Label("New idea to build", systemImage: "hammer") }
                        Button { jot = .note } label: { Label("New note", systemImage: "note.text") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New")
                }
            }
            .sheet(item: $jot) { kind in JotSheet(initialKind: kind) }
        }
    }

    private func setTrack(_ idea: Idea, _ track: IdeaTrack) {
        var copy = idea
        copy.track = track
        if track == .queued && copy.phases.isEmpty { copy.phases = IdeaSize.m.phases() }
        store.update(copy)
    }
}

struct IdeaRow: View {
    let idea: Idea
    let forecast: Forecast?
    let now: Date

    private var trailing: (String, Color)? {
        switch idea.track {
        case .shipped: return ("SHIPPED", BossPalette.now)
        case .paused: return ("PAUSED", BossPalette.secondary)
        case .note: return nil
        case .queued:
            if idea.remainingMinutes == 0 { return ("READY TO SHIP", BossPalette.now) }
            if let next = forecast?.nextBlock { return (Fmt.departure(next, now: now).uppercased(), BossPalette.build) }
            return ("NO SLOT", BossPalette.warning)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(idea.title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(BossPalette.ink)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing.0)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(trailing.1)
                        .lineLimit(1)
                }
            }
            if idea.track == .note {
                Text(idea.body.isEmpty ? "Empty note" : idea.body)
                    .font(.subheadline)
                    .foregroundStyle(BossPalette.secondary)
                    .lineLimit(2)
            } else {
                HStack(spacing: 8) {
                    HeatPips(heat: idea.heat)
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(BossPalette.secondary)
                        .lineLimit(1)
                }
                ProgressCapsule(progress: idea.progress)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let phase = idea.currentPhase { parts.append(phase.title) }
        parts.append("\(BossFormat.hours(minutes: idea.remainingMinutes)) left")
        if let f = forecast, let finish = f.finish, idea.track == .queued {
            parts.append((f.estimated ? "~" : "done ") + Fmt.shortDate(finish))
        }
        return parts.joined(separator: " · ")
    }
}
