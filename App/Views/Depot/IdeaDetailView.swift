import BossCore
import SwiftUI
import OfflineIntelligence

/// An idea is a note with a build plan: title, body, heat, deadline and phases. Edits save live.
struct IdeaDetailView: View {
    let ideaID: UUID
    @Environment(BossStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(OfflineModelChoice.preferenceKey) private var offlineModel = OfflineModelChoice.defaultChoice.rawValue
    @State private var draft: Idea?
    @State private var shaping = false
    @State private var shapeError: String?
    @State private var shapeSummary: String?
    @State private var confirmDelete = false
    @State private var confirmReshape: PendingReshape?
    @State private var proposedPlan: IdeaShaper.Result?
    @State private var shapeTask: Task<Void, Never>?
    @FocusState private var bodyFocused: Bool

    var body: some View {
        Group {
            if let draft {
                editor(Binding(get: { self.draft ?? draft }, set: { self.draft = $0; store.update($0) }))
            } else {
                ContentUnavailableView("Idea deleted", systemImage: "trash")
            }
        }
        .background { InstrumentDesignBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = store.idea(ideaID) }
        .onChange(of: store.idea(ideaID)) { _, latest in draft = latest }
        .onDisappear { shapeTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { shapeTask?.cancel() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { bodyFocused = false }
            }
        }
        .confirmationDialog("Delete this idea and its planned blocks?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteIdea(ideaID)
                draft = nil
                dismiss()
            }
        }
        .confirmationDialog("Replace phases? Logged time is kept and re-applied in order.",
                            isPresented: Binding(get: { confirmReshape != nil }, set: { if !$0 { confirmReshape = nil } }),
                            titleVisibility: .visible) {
            Button("Replace phases") {
                if let plan = confirmReshape { apply(plan.phases, source: plan.source, summary: plan.summary) }
            }
        }
    }

    @ViewBuilder
    private func editor(_ idea: Binding<Idea>) -> some View {
        let forecast = store.forecasts[ideaID]
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Idea title", text: idea.title, axis: .vertical)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(BossPalette.ink)
                    .padding(.horizontal, 12)

                Picker("Track", selection: Binding(get: { idea.wrappedValue.track }, set: { track in
                    var copy = idea.wrappedValue
                    copy.track = track
                    if track != .note && copy.phases.isEmpty { copy.phases = IdeaSize.m.phases() }
                    idea.wrappedValue = copy
                })) {
                    ForEach(IdeaTrack.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)

                if idea.wrappedValue.track != .note {
                    InstrumentContentPanel {
                        HStack(spacing: 0) {
                            InstrumentMetricReadout("LEFT", value: BossFormat.hoursValue(minutes: idea.wrappedValue.remainingMinutes), unit: "h")
                            Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                            InstrumentMetricReadout("DONE", value: "\(Int((idea.wrappedValue.progress * 100).rounded()))", unit: "%")
                            Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                            InstrumentMetricReadout("FINISH", value: finishText(forecast, idea.wrappedValue),
                                                    unit: forecast?.estimated == true ? "est." : "", color: BossPalette.now)
                        }
                    }

                    VStack(spacing: 6) {
                        InstrumentParameterStepper("HEAT", value: Binding(get: { idea.wrappedValue.heat }, set: { idea.wrappedValue.heat = $0 }),
                                                   in: 1...5, unit: "/ 5")
                        Text(BossMeaning.heat(idea.wrappedValue.heat))
                            .font(.system(.subheadline, design: .serif, weight: .medium)).italic()
                            .foregroundStyle(BossPalette.build)
                    }
                    .frame(maxWidth: .infinity)

                    InstrumentContentPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(get: { idea.wrappedValue.deadline != nil }, set: { on in
                                idea.wrappedValue.deadline = on ? endOfDay(Date.now.addingTimeInterval(7 * 86_400)) : nil
                            })) {
                                SectionLabel(text: "DEADLINE")
                            }
                            .tint(BossPalette.build)
                            if let deadline = idea.wrappedValue.deadline {
                                DatePicker("Ship by", selection: Binding(get: { deadline }, set: { idea.wrappedValue.deadline = endOfDay($0) }),
                                           in: Date.now..., displayedComponents: .date)
                                    .font(.system(.body, design: .rounded))
                            }
                        }
                    }
                }

                InstrumentContentPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: idea.wrappedValue.track == .note ? "NOTE" : "NOTES")
                        TextEditor(text: idea.body)
                            .focused($bodyFocused)
                            .scrollContentBackground(.hidden)
                            .font(.body)
                            .foregroundStyle(BossPalette.ink)
                            .frame(minHeight: 140)
                            .overlay(alignment: .topLeading) {
                                if idea.wrappedValue.body.isEmpty {
                                    Text("What is it, who is it for, what makes it fun?")
                                        .foregroundStyle(BossPalette.secondary.opacity(0.6))
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }

                if idea.wrappedValue.track != .note {
                    phasesPanel(idea)
                    shapePanel(idea)
                    blocksPanel(idea.wrappedValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func phasesPanel(_ idea: Binding<Idea>) -> some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "PHASES", trailing: BossFormat.hours(minutes: idea.wrappedValue.plannedMinutes).uppercased() + " TOTAL")
                ForEach(idea.phases) { $phase in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Phase", text: $phase.title)
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(phase.remainingMinutes == 0 ? BossPalette.secondary : BossPalette.ink)
                            Menu {
                                Button { move(idea, phase.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                                Button { move(idea, phase.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                                Button { idea.wrappedValue.phases.removeAll { $0.id == phase.id } } label: {
                                    Label("Delete phase", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(BossPalette.secondary)
                                    .frame(width: 44, height: 32)
                            }
                            .accessibilityLabel("Phase options")
                        }
                        MinuteStepper(label: "PLAN", minutes: $phase.plannedMinutes, range: 15...(80 * 60), step: 30)
                        HStack {
                            ProgressCapsule(progress: phase.plannedMinutes == 0 ? 0 : Double(phase.doneMinutes) / Double(phase.plannedMinutes))
                            Text("\(BossFormat.hours(minutes: phase.doneMinutes)) logged")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(BossPalette.secondary)
                        }
                    }
                    Divider().overlay(.white.opacity(0.06))
                }
                Button {
                    idea.wrappedValue.phases.append(Phase(title: "New phase", plannedMinutes: 120))
                } label: {
                    Label("Add phase", systemImage: "plus")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(BossPalette.build)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func shapePanel(_ idea: Binding<Idea>) -> some View {
        InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "SHAPE", trailing: "BY " + idea.wrappedValue.shapedBy.title.uppercased())
                switch IdeaShaper.status(for: modelChoice) {
                case .available:
                    Text("\(modelChoice.title) reads your note on this iPhone and proposes phases with hours. Review them before using them.")
                        .font(.subheadline).foregroundStyle(BossPalette.secondary)
                    GlassActionButton(title: shaping ? "Shaping…" : "Shape with \(modelChoice.title)",
                                      symbol: "sparkles", prominent: true) {
                        beginShape(idea.wrappedValue)
                    }
                    .disabled(shaping)
                    .accessibilityIdentifier("shape-idea")
                    if shaping {
                        GlassActionButton(title: "Stop shaping", symbol: "stop.fill") { shapeTask?.cancel() }
                    }
                case .unavailable(let reason):
                    Text("\(reason). Pick a size template instead.")
                        .font(.subheadline).foregroundStyle(BossPalette.secondary)
                }
                if let proposal = proposedPlan {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "PROPOSED · " + proposal.modelTitle.uppercased(),
                                     trailing: BossFormat.hours(minutes: proposal.phases.reduce(0) { $0 + $1.plannedMinutes }))
                        Text(proposal.summary).font(.subheadline).foregroundStyle(BossPalette.ink)
                        ForEach(proposal.phases) { phase in
                            HStack {
                                Text(phase.title)
                                Spacer()
                                Text(BossFormat.hours(minutes: phase.plannedMinutes)).monospacedDigit()
                            }.font(.subheadline).foregroundStyle(BossPalette.secondary)
                        }
                        Text("Your current phases and booked blocks stay as they are until you accept this proposal.")
                            .font(.caption).foregroundStyle(BossPalette.secondary)
                        HStack {
                            GlassActionButton(title: "Use these phases", symbol: "checkmark", prominent: true) {
                                if idea.wrappedValue.doneMinutes > 0 {
                                    confirmReshape = PendingReshape(phases: proposal.phases, source: proposal.source, summary: proposal.summary)
                                } else { apply(proposal.phases, source: proposal.source, summary: proposal.summary) }
                            }.accessibilityIdentifier("accept-shaped-phases")
                            GlassActionButton(title: "Discard", symbol: "xmark") { proposedPlan = nil }
                        }
                    }.padding(.vertical, 8)
                }
                if let shapeSummary {
                    Text(shapeSummary).font(.system(.subheadline, design: .serif)).italic().foregroundStyle(BossPalette.build)
                }
                if let shapeError {
                    Label(shapeError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(BossPalette.now)
                }
                Text("TEMPLATES").font(.system(.caption2, design: .monospaced)).tracking(1.2).foregroundStyle(BossPalette.secondary)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(IdeaSize.allCases) { size in
                            Button {
                                let phases = size.phases()
                                if idea.wrappedValue.doneMinutes > 0 {
                                    confirmReshape = PendingReshape(phases: phases, source: .template)
                                } else { apply(phases, source: .template) }
                            } label: {
                                VStack(spacing: 1) {
                                    Text(size.rawValue).font(.system(.headline, design: .rounded))
                                    Text("\(size.hours)h").font(.system(.caption2, design: .monospaced))
                                }
                                .foregroundStyle(BossPalette.build)
                                .frame(minWidth: 58, minHeight: 48)
                                .glassEffect(.regular.tint(BossPalette.build.opacity(0.08)).interactive(), in: .rect(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(size.title), \(size.hours) hours")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func blocksPanel(_ idea: Idea) -> some View {
        let blocks = store.state.blocks.filter { $0.ideaID == idea.id && $0.end > store.now.addingTimeInterval(-7 * 86_400) }
        return InstrumentContentPanel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "BLOCKS", trailing: "\(blocks.filter { $0.state == .planned && $0.start > store.now }.count) BOOKED")
                if blocks.isEmpty {
                    Text(idea.track == .queued ? "No block yet — the Boss is out of free build time in this horizon."
                                               : "Set the track to Build to get blocks.")
                        .font(.subheadline).foregroundStyle(BossPalette.secondary)
                }
                ForEach(blocks.prefix(12)) { b in
                    DepartureRow(block: b, title: Fmt.departure(b.start, now: store.now), now: store.now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func finishText(_ forecast: Forecast?, _ idea: Idea) -> String {
        if idea.remainingMinutes == 0 { return "now" }
        guard let finish = forecast?.finish else { return "—" }
        return Fmt.shortDate(finish)
    }

    private func endOfDay(_ date: Date) -> Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
    }

    private func move(_ idea: Binding<Idea>, _ id: UUID, by offset: Int) {
        var phases = idea.wrappedValue.phases
        guard let i = phases.firstIndex(where: { $0.id == id }) else { return }
        let j = min(phases.count - 1, max(0, i + offset))
        guard i != j else { return }
        phases.swapAt(i, j)
        idea.wrappedValue.phases = phases
    }

    private func apply(_ phases: [Phase], source: ShapeSource, summary: String? = nil) {
        guard var copy = draft else { return }
        let logged = copy.doneMinutes
        copy.phases = phases
        copy.shapedBy = source
        proposedPlan = nil
        shapeSummary = summary
        if logged > 0 { copy.credit(minutes: logged) }
        draft = copy
        store.update(copy)
    }

    private var modelChoice: OfflineModelChoice { OfflineModelChoice(rawValue: offlineModel) ?? .defaultChoice }

    private func beginShape(_ idea: Idea) {
        guard !shaping else { return }
        shaping = true
        shapeError = nil
        proposedPlan = nil
        let choice = modelChoice
        shapeTask = Task { await shape(idea, choice: choice) }
    }

    private func shape(_ idea: Idea, choice: OfflineModelChoice) async {
        defer { shaping = false; shapeTask = nil }
        do {
            let result = try await IdeaShaper.shape(title: idea.title, body: idea.body, choice: choice)
            try Task.checkCancellation()
            proposedPlan = result
        } catch is CancellationError {
            shapeError = "Shaping stopped. Your current phases were kept."
        } catch {
            shapeError = "Couldn't shape this one: \(error.localizedDescription) Your current phases were kept; size templates still work."
        }
    }
}

private struct PendingReshape {
    let phases: [Phase]
    let source: ShapeSource
    var summary: String? = nil
}
