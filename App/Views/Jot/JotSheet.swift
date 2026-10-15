import BossCore
import SwiftUI

enum JotKind: String, CaseIterable, Identifiable {
    case idea, note, nudge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: "Idea to build"
        case .note: "Just a note"
        case .nudge: "Nudge"
        }
    }
    var symbol: String {
        switch self {
        case .idea: "hammer"
        case .note: "note.text"
        case .nudge: "bell"
        }
    }
}

/// Universal capture. First line = title, the rest = note. Nudges read a time out of the text.
struct JotSheet: View {
    var initialKind: JotKind = .idea
    @Environment(BossStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind: JotKind = .idea
    @State private var size: IdeaSize = .m
    @State private var heat = 3
    @State private var due = Date.now.addingTimeInterval(3600)
    @State private var dueTouched = false
    @State private var detected: NaturalDate.Match?
    @State private var ideaLink: UUID?
    @FocusState private var focused: Bool

    private var title: String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if kind == .nudge, let detected, !dueTouched { return detected.title }
        return first.trimmingCharacters(in: .whitespaces)
    }

    private var body_: String {
        let parts = text.split(separator: "\n", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Kind", selection: $kind) {
                        ForEach(JotKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    InstrumentContentPanel {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .focused($focused)
                            .font(.system(.title3, design: .rounded))
                            .foregroundStyle(BossPalette.ink)
                            .lineLimit(3...10)
                            .submitLabel(.return)
                    }

                    switch kind {
                    case .idea: ideaOptions
                    case .note:
                        Text("Notes live in the Depot and never get scheduled. Flip one to Build any time.")
                            .font(.subheadline).foregroundStyle(BossPalette.secondary)
                    case .nudge: nudgeOptions
                    }
                }
                .padding(20)
            }
            .background { InstrumentDesignBackground() }
            .navigationTitle("Jot it down")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind == .idea ? "Hand to Boss" : "Save") { save() }
                        .disabled(title.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(BossPalette.panel)
        .onAppear {
            kind = initialKind
            focused = true
        }
        .onChange(of: text) { _, new in
            detected = NaturalDate.parse(new)
            if let detected, !dueTouched { due = detected.date }
        }
    }

    private var placeholder: String {
        switch kind {
        case .idea: "An app that… (first line is the title)"
        case .note: "Note title\nand the rest of the note"
        case .nudge: "Email Sam friday 4pm"
        }
    }

    private var ideaOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "SIZE", trailing: "\(size.title.uppercased()) · \(size.hours) H")
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(IdeaSize.allCases) { option in
                        Button { size = option } label: {
                            Text(option.rawValue)
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(option == size ? Color.black.opacity(0.85) : BossPalette.build)
                                .frame(minWidth: 58, minHeight: 44)
                                .glassEffect(option == size ? .regular.tint(BossPalette.build.opacity(0.85)).interactive()
                                                            : .regular.tint(BossPalette.build.opacity(0.08)).interactive(),
                                             in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.title), \(option.hours) hours")
                        .accessibilityAddTraits(option == size ? .isSelected : [])
                    }
                }
            }
            InstrumentParameterStepper("HEAT", value: $heat, in: 1...5, unit: "/ 5")
            Text("\(BossMeaning.heat(heat)) — the Boss books hotter ideas first. Shape phases later in the Depot.")
                .font(.footnote).foregroundStyle(BossPalette.secondary)
        }
    }

    private var nudgeOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if detected != nil && !dueTouched {
                Label("Time found in your text", systemImage: "sparkles")
                    .font(.footnote).foregroundStyle(BossPalette.build)
            }
            DatePicker("When", selection: Binding(get: { due }, set: { due = $0; dueTouched = true }))
                .font(.system(.body, design: .rounded))
            Picker("Attach to idea", selection: $ideaLink) {
                Text("None").tag(UUID?.none)
                ForEach(store.state.ideas.filter { $0.track != .shipped }) { Text($0.title).tag(UUID?.some($0.id)) }
            }
            .tint(BossPalette.build)
        }
    }

    private func save() {
        switch kind {
        case .idea: store.addIdea(title: title, body: body_, track: .queued, size: size, heat: heat)
        case .note: store.addIdea(title: title, body: body_, track: .note)
        case .nudge: store.addNudge(title: title, due: due, ideaID: ideaLink)
        }
        dismiss()
    }
}
