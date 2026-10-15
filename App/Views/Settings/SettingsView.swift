import BossCore
import SwiftUI
import OfflineIntelligence
import OfflineIntelligenceMLX

struct SettingsView: View {
    @Environment(BossStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @AppStorage(OfflineModelChoice.preferenceKey) private var offlineModel = OfflineModelChoice.defaultChoice.rawValue

    private var settings: PlannerSettings { store.state.settings }

    private func bind<T>(_ key: WritableKeyPath<PlannerSettings, T>) -> Binding<T> {
        Binding(get: { store.state.settings[keyPath: key] },
                set: { value in store.updateSettings { $0[keyPath: key] = value } })
    }

    private let weekdays: [(Int, String)] = {
        let symbols = Calendar.current.weekdaySymbols
        // Monday-first ordering.
        return [2, 3, 4, 5, 6, 7, 1].map { ($0, symbols[$0 - 1]) }
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(weekdays, id: \.0) { weekday, name in
                        let windows = store.state.windows.filter { $0.weekday == weekday }.sorted { $0.startMinute < $1.startMinute }
                        ForEach(windows) { window in
                            WindowRow(name: name, window: window) { updated in
                                store.updateWindows { all in
                                    if let i = all.firstIndex(where: { $0.id == updated.id }) { all[i] = updated }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { windows[$0].id }
                            store.updateWindows { $0.removeAll { ids.contains($0.id) } }
                        }
                    }
                    Menu {
                        ForEach(weekdays, id: \.0) { weekday, name in
                            Button(name) {
                                store.updateWindows { $0.append(.h(weekday, 19, 21)) }
                            }
                        }
                    } label: {
                        Label("Add build window", systemImage: "plus")
                    }
                } header: {
                    Text("Build windows")
                } footer: {
                    Text("When you're willing to build. The Boss books blocks only inside these, around your calendar. \(totalWindowHours) h a week available.")
                }

                Section {
                    Stepper("Weekly hours: \(settings.weeklyBudgetHours) h", value: bind(\.weeklyBudgetHours), in: 1...60)
                    Stepper("Block length: \(BossFormat.hours(minutes: settings.blockMinutes))", value: bind(\.blockMinutes), in: 30...180, step: 15)
                    Stepper("Shortest block: \(settings.minBlockMinutes) min", value: bind(\.minBlockMinutes), in: 15...max(15, settings.blockMinutes), step: 15)
                    Stepper("Break between blocks: \(settings.breakMinutes) min", value: bind(\.breakMinutes), in: 0...60, step: 5)
                    Stepper("Blocks per day: \(settings.maxBlocksPerDay)", value: bind(\.maxBlocksPerDay), in: 1...6)
                    Stepper("Focus: \(settings.focusLimit) idea\(settings.focusLimit == 1 ? "" : "s") a week", value: bind(\.focusLimit), in: 1...6)
                    Stepper("Keep plan steady: \(settings.freezeHours) h", value: bind(\.freezeHours), in: 0...48, step: 6)
                    Stepper("Plan ahead: \(settings.horizonDays) days", value: bind(\.horizonDays), in: 7...42, step: 7)
                } header: {
                    Text("Autopilot")
                } footer: {
                    Text("Focus caps how many different ideas get blocks in one week, so things finish. Keep plan steady stops blocks in the next few hours from reshuffling.")
                }

                Section {
                    Toggle("Plan around Apple Calendar", isOn: bind(\.useAppleCalendar)).tint(BossPalette.build)
                    Stepper("Buffer around events: \(settings.busyBufferMinutes) min", value: bind(\.busyBufferMinutes), in: 0...60, step: 5)
                    switch store.calendarAccess {
                    case .granted:
                        Label("Reading busy time from \(store.busyEvents.count) upcoming events", systemImage: "checkmark.circle")
                            .foregroundStyle(BossPalette.secondary)
                    case .notDetermined:
                        Button("Allow calendar access") { Task { await store.requestCalendarAccess() } }
                    case .denied:
                        Button("Calendar access is off — open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("Apple Calendar")
                } footer: {
                    Text("Read-only. Timed events marked busy block build time; all-day and free events don't.")
                }

                Section("Notifications") {
                    Toggle("Block reminders and check-ins", isOn: bind(\.notifyBlocks)).tint(BossPalette.build)
                    Stepper("Heads-up: \(settings.leadMinutes) min before", value: bind(\.leadMinutes), in: 0...30, step: 5)
                }

                Section {
                    Picker("Idea shaping model", selection: $offlineModel) {
                        ForEach(OfflineModelChoice.allCases) { choice in Text(choice.title).tag(choice.rawValue) }
                    }.accessibilityIdentifier("shaping-model-choice")
                    Text((OfflineModelChoice(rawValue: offlineModel) ?? .defaultChoice).detail)
                        .font(.caption).foregroundStyle(BossPalette.secondary)
                } header: {
                    Text("Offline intelligence")
                } footer: {
                    Text("Models run on this iPhone. Review proposed phases before using them. Size templates work without a model.")
                }

                Section("Data") {
                    Button("Load demo pipeline") { store.loadDemo() }
                    Button("Start empty", role: .destructive) { confirmEmpty = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background { InstrumentDesignBackground() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: offlineModel) { _, _ in
                Task { await OfflineTextService.shared.unload() }
            }
            .confirmationDialog("Delete all ideas, notes, blocks and nudges?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Start empty", role: .destructive) { store.startEmpty() }
            }
        }
        .tint(BossPalette.build)
    }

    private var totalWindowHours: String {
        BossFormat.hoursValue(minutes: store.state.windows.reduce(0) { $0 + $1.minutes })
    }
}

private struct WindowRow: View {
    let name: String
    let window: BuildWindow
    let onChange: (BuildWindow) -> Void

    private func date(_ minute: Int) -> Date {
        TimeMath.date(.now, minuteOfDay: min(minute, 23 * 60 + 45), calendar: .current)
    }

    private func minute(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        HStack {
            Text(name).font(.system(.body, design: .rounded)).frame(minWidth: 90, alignment: .leading)
            Spacer()
            DatePicker("Start", selection: Binding(get: { date(window.startMinute) }, set: {
                var w = window
                w.startMinute = minute($0)
                if w.endMinute <= w.startMinute { w.endMinute = min(1440, w.startMinute + 60) }
                onChange(w)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            Text("–").foregroundStyle(BossPalette.secondary)
            DatePicker("End", selection: Binding(get: { date(window.endMinute == 1440 ? 1439 : window.endMinute) }, set: {
                var w = window
                let m = minute($0)
                w.endMinute = m == 1439 ? 1440 : max(w.startMinute + 15, m)
                onChange(w)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) window")
    }
}
