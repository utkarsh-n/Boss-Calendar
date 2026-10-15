import BossCore
import SwiftUI

struct NudgeRef: Identifiable, Hashable { let id: UUID }

/// Nudges: reminders, standalone or attached to an idea.
struct NudgesView: View {
    @Environment(BossStore.self) private var store
    @State private var editing: NudgeRef?
    @State private var adding = false

    private var cal: Calendar { .current }

    private var sections: [(String, [Nudge], Color)] {
        let now = store.now
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let open = store.state.nudges.filter { !$0.done }.sorted { $0.due < $1.due }
        return [
            ("OVERDUE", open.filter { $0.due < now }, BossPalette.now),
            ("TODAY", open.filter { $0.due >= now && $0.due < endOfToday }, BossPalette.build),
            ("UPCOMING", open.filter { $0.due >= endOfToday }, BossPalette.build),
            ("DONE", store.state.nudges.filter(\.done).sorted { $0.due > $1.due }.prefix(20).map { $0 }, BossPalette.secondary)
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.state.nudges.isEmpty {
                    ContentUnavailableView("No nudges", systemImage: "bell",
                                           description: Text("Jot something like “email Sam friday 4pm” and pick Nudge."))
                        .listRowBackground(Color.clear)
                }
                ForEach(sections, id: \.0) { section in
                    Section {
                        ForEach(section.1) { nudge in
                            NudgeRow(nudge: nudge, ideaTitle: store.idea(nudge.ideaID)?.title, now: store.now) {
                                withAnimation(.snappy) { store.toggleNudge(nudge.id) }
                            }
                            .contentShape(.rect)
                            .onTapGesture { editing = NudgeRef(id: nudge.id) }
                            .bossRow()
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteNudge(nudge.id) } label: { Label("Delete", systemImage: "trash") }
                                if !nudge.done {
                                    Button { store.snoozeNudge(nudge.id, minutes: 60) } label: { Label("1 h", systemImage: "zzz") }
                                        .tint(BossPalette.now)
                                }
                            }
                        }
                    } header: {
                        SectionLabel(text: section.0, color: section.2, trailing: "\(section.1.count)")
                    }
                }
            }
            .bossListStyle()
            .navigationTitle("Nudges")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("New nudge")
                }
            }
            .sheet(item: $editing) { ref in NudgeEditor(nudgeID: ref.id) }
            .sheet(isPresented: $adding) { JotSheet(initialKind: .nudge) }
        }
    }
}

struct NudgeEditor: View {
    let nudgeID: UUID
    @Environment(BossStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Nudge?

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    let binding = Binding(get: { self.draft ?? draft }, set: { self.draft = $0 })
                    TextField("Reminder", text: binding.title, axis: .vertical)
                        .font(.system(.title3, design: .rounded))
                    DatePicker("When", selection: binding.due)
                    Picker("Idea", selection: binding.ideaID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.state.ideas) { Text($0.title).tag(UUID?.some($0.id)) }
                    }
                    Toggle("Done", isOn: binding.done).tint(BossPalette.build)
                    Section {
                        Button("Delete nudge", role: .destructive) {
                            store.deleteNudge(nudgeID)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BossPalette.panel)
            .navigationTitle("Nudge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let draft { store.updateNudge(draft) }
                        dismiss()
                    }
                }
            }
            .onAppear { draft = store.state.nudges.first { $0.id == nudgeID } }
        }
        .presentationDetents([.medium, .large])
    }
}
