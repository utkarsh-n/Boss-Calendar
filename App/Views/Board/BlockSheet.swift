import BossCore
import SwiftUI

/// One build block: move it, lock it, check in, or open its idea.
struct BlockSheet: View {
    let blockID: UUID
    @Environment(BossStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var moveError: String?
    @State private var feedback = 0

    var body: some View {
        NavigationStack {
            Group {
                if let block = store.block(blockID) {
                    content(block)
                } else {
                    ContentUnavailableView("Block re-planned", systemImage: "arrow.triangle.2.circlepath",
                                           description: Text("The Boss moved or removed this block."))
                }
            }
            .background { InstrumentDesignBackground() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(BossPalette.panel)
        .sensoryFeedback(.selection, trigger: feedback)
    }

    @ViewBuilder
    private func content(_ block: Block) -> some View {
        let idea = store.idea(block.ideaID)
        let isPast = block.end <= store.now
        let isRunning = block.start <= store.now && !isPast
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateLabel(block, running: isRunning, past: isPast))
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(isRunning ? BossPalette.now : BossPalette.build)
                    Text(idea?.title ?? "Idea")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(BossPalette.ink)
                    Text(block.phaseTitle)
                        .font(.system(.title3, design: .serif)).italic()
                        .foregroundStyle(BossPalette.build)
                }
                InstrumentContentPanel {
                    HStack(spacing: 0) {
                        InstrumentMetricReadout("START", value: Fmt.time(block.start), unit: Fmt.weekday(block.start))
                        Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                        InstrumentMetricReadout("LENGTH", value: BossFormat.hoursValue(minutes: block.minutes),
                                                unit: block.minutes < 60 ? "min" : "h")
                        Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 30)
                        InstrumentMetricReadout("END", value: Fmt.time(block.end), unit: "")
                    }
                }

                if block.state == .planned && !isPast && !isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "MOVE", trailing: "15 MIN STEPS · LOCKS IN PLACE")
                        HStack(spacing: 10) {
                            GlassEffectContainer(spacing: 10) {
                                HStack(spacing: 10) {
                                    moveButton(block, -60, "−1 h")
                                    moveButton(block, -15, "−15")
                                    moveButton(block, 15, "+15")
                                    moveButton(block, 60, "+1 h")
                                }
                            }
                        }
                        if let moveError {
                            Label(moveError, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(BossPalette.now)
                        }
                        Toggle(isOn: Binding(get: { block.locked }, set: { store.setLocked(block.id, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lock in place").font(.system(.body, design: .rounded))
                                Text("Autopilot never moves a locked block.").font(.caption).foregroundStyle(BossPalette.secondary)
                            }
                        }
                        .tint(BossPalette.build)
                        .padding(.top, 4)
                    }
                }

                if block.state == .planned {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            GlassActionButton(title: isPast || isRunning ? "Built it" : "Done early", symbol: "checkmark", prominent: true) {
                                store.checkIn(block.id, built: true)
                                dismiss()
                            }
                            GlassActionButton(title: "Skip", symbol: "arrow.uturn.forward", accent: BossPalette.secondary) {
                                store.checkIn(block.id, built: false)
                                dismiss()
                            }
                        }
                    }
                }

                if let idea {
                    NavigationLink {
                        IdeaDetailView(ideaID: idea.id)
                    } label: {
                        HStack {
                            Label("Open \(idea.title)", systemImage: "doc.text")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(BossPalette.secondary)
                        }
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(BossPalette.ink)
                        .padding(16)
                        .background(BossPalette.plot, in: .rect(cornerRadius: 16))
                    }
                }
            }
            .padding(20)
        }
    }

    private func stateLabel(_ block: Block, running: Bool, past: Bool) -> String {
        switch block.state {
        case .done: return "DONE"
        case .skipped: return "SKIPPED"
        case .planned:
            if running { return "BUILDING NOW" }
            if past { return "WAITING FOR CHECK-IN" }
            return (block.locked ? "LOCKED · " : "") + Fmt.departure(block.start, now: store.now).uppercased()
        }
    }

    private func moveButton(_ block: Block, _ minutes: Int, _ label: String) -> some View {
        Button {
            moveError = store.move(block.id, byMinutes: minutes)
            if moveError == nil { feedback += 1 }
        } label: {
            Text(label)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(BossPalette.build)
                .frame(minWidth: 54, minHeight: 44)
                .glassEffect(.regular.tint(BossPalette.build.opacity(0.08)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(minutes > 0 ? "Later by \(BossFormat.spokenDuration(minutes: minutes))"
                                        : "Earlier by \(BossFormat.spokenDuration(minutes: -minutes))")
    }
}
