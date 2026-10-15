import AppIntents
import BossCore
import Foundation

struct JotIdeaIntent: AppIntent {
    static let title: LocalizedStringResource = "Jot an Idea"
    static let description = IntentDescription("Hands an app idea to the Boss, who books build blocks for it.")
    static let openAppWhenRun = false

    @Parameter(title: "Idea", requestValueDialog: "What's the idea?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = BossStore.shared
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? text
        let id = store.addIdea(title: title, body: lines.count > 1 ? lines[1] : "")
        store.saveNow()
        if let next = store.forecasts[id]?.nextBlock {
            return .result(dialog: "Booked. First build block \(Fmt.departure(next)).")
        }
        return .result(dialog: "Queued. No free build block in the next few weeks — add build windows.")
    }
}

struct JotNudgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Nudge"
    static let description = IntentDescription("Sets a reminder in Boss Calendar.")
    static let openAppWhenRun = false

    @Parameter(title: "Reminder")
    var text: String

    @Parameter(title: "When")
    var due: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        BossStore.shared.addNudge(title: text, due: due)
        BossStore.shared.saveNow()
        return .result(dialog: "Nudge set for \(Fmt.departure(due)).")
    }
}

struct BossShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: JotIdeaIntent(),
                    phrases: ["Jot an idea in \(.applicationName)", "Tell \(.applicationName) an idea",
                              "New idea in \(.applicationName)"],
                    shortTitle: "Jot Idea", systemImageName: "square.and.pencil")
        AppShortcut(intent: JotNudgeIntent(),
                    phrases: ["Add a nudge in \(.applicationName)", "Remind me with \(.applicationName)"],
                    shortTitle: "Add Nudge", systemImageName: "bell.badge")
    }
}
