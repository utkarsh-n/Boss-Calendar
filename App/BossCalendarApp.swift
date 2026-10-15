import BossCore
import SwiftUI
import UserNotifications
import OfflineIntelligenceMLX

@main
struct BossCalendarApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = BossStore.shared

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationScheduler.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(BossPalette.build)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await OfflineTextService.shared.unload() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await store.refresh() }
            case .inactive: Task { await OfflineTextService.shared.cancel() }
            case .background:
                store.saveNow()
                Task { await OfflineTextService.shared.unload() }
            @unknown default: break
            }
        }
    }
}

enum AppTab: String, Hashable {
    case station, board, depot, nudges
}

struct RootView: View {
    @Environment(BossStore.self) private var store
    @State private var tab: AppTab = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = AppTab(rawValue: args[i + 1]) { return t }
        return .station
    }()
    @State private var jotting: JotKind?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Station", systemImage: "gauge.with.dots.needle.33percent", value: AppTab.station) { StationView() }
            Tab("Board", systemImage: "calendar", value: AppTab.board) { BoardView() }
            Tab("Depot", systemImage: "tram", value: AppTab.depot) { DepotView() }
            Tab("Nudges", systemImage: "bell", value: AppTab.nudges) { NudgesView() }
                .badge(overdue)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            Button { jotting = tab == .nudges ? .nudge : .idea } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(BossPalette.build)
                    Text("Jot it down…")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(BossPalette.secondary)
                    Spacer()
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BossPalette.build)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jot an idea, note or nudge")
        }
        .sheet(item: $jotting) { kind in JotSheet(initialKind: kind) }
        .overlay(alignment: .top) {
            if let banner = store.banner {
                Text(banner)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(BossPalette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(BossPalette.build.opacity(0.10)), in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .onTapGesture { store.banner = nil }
            }
        }
        .animation(.snappy, value: store.banner)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-jot") { jotting = .idea }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                store.tick()
            }
        }
    }

    private var overdue: Int {
        store.state.nudges.filter { !$0.done && $0.due < store.now }.count
    }
}
