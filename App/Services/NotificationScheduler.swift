import BossCore
import Foundation
import UserNotifications

/// Re-derives every pending Boss notification from state after each plan; nothing is patched incrementally.
enum NotificationScheduler {
    static let prefix = "boss."
    static let blockCategory = "BOSS_BLOCK"
    static let checkInCategory = "BOSS_CHECKIN"
    static let nudgeCategory = "BOSS_NUDGE"

    static func registerCategories() {
        let skip = UNNotificationAction(identifier: "SKIP", title: "Skip this block", options: [.destructive])
        let built = UNNotificationAction(identifier: "BUILT", title: "Built it")
        let skipped = UNNotificationAction(identifier: "SKIPPED", title: "Skipped", options: [.destructive])
        let done = UNNotificationAction(identifier: "DONE", title: "Done")
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 15 min")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: blockCategory, actions: [skip], intentIdentifiers: []),
            UNNotificationCategory(identifier: checkInCategory, actions: [built, skipped], intentIdentifiers: []),
            UNNotificationCategory(identifier: nudgeCategory, actions: [done, snooze], intentIdentifiers: [])
        ])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func sync(_ state: BossState) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, state.settings.notifyBlocks || !state.nudges.isEmpty {
            guard await requestAuthorization() else { return }
        } else if settings.authorizationStatus == .denied {
            return
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        let now = Date.now
        var requests: [UNNotificationRequest] = []
        if state.settings.notifyBlocks {
            let upcoming = state.blocks.filter { $0.state == .planned && $0.end > now }.prefix(20)
            for block in upcoming {
                let title = state.idea(block.ideaID)?.title ?? "Build block"
                let fire = block.start.addingTimeInterval(TimeInterval(-state.settings.leadMinutes * 60))
                if fire > now {
                    let content = UNMutableNotificationContent()
                    content.title = "Boss: \(title) · \(block.phaseTitle)"
                    content.body = "\(BossFormat.hours(minutes: block.minutes)) build block at \(Fmt.time(block.start)). Phone down, editor up."
                    content.sound = .default
                    content.categoryIdentifier = blockCategory
                    content.userInfo = ["block": block.id.uuidString]
                    requests.append(request("\(prefix)start.\(block.id)", content, fire))
                }
                let content = UNMutableNotificationContent()
                content.title = "Did you build \(title)?"
                content.body = "\(block.phaseTitle) · \(Fmt.time(block.start))–\(Fmt.time(block.end)). Tell the Boss so it can re-plan."
                content.sound = .default
                content.categoryIdentifier = checkInCategory
                content.userInfo = ["block": block.id.uuidString]
                requests.append(request("\(prefix)checkin.\(block.id)", content, block.end))
            }
        }
        for nudge in state.nudges.filter({ !$0.done && $0.due > now }).sorted(by: { $0.due < $1.due }).prefix(20) {
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            if let ideaID = nudge.ideaID, let idea = state.idea(ideaID) { content.subtitle = idea.title }
            content.body = "Nudge from the Boss"
            content.sound = .default
            content.categoryIdentifier = nudgeCategory
            content.userInfo = ["nudge": nudge.id.uuidString]
            requests.append(request("\(prefix)nudge.\(nudge.id)", content, nudge.due))
        }
        for request in requests.prefix(60) {
            try? await center.add(request)
        }
    }

    private static func request(_ id: String, _ content: UNNotificationContent, _ date: Date) -> UNNotificationRequest {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNNotificationRequest(identifier: id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}

/// Routes notification actions back into the store.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let block = (info["block"] as? String).flatMap(UUID.init(uuidString:))
        let nudge = (info["nudge"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            let store = BossStore.shared
            switch action {
            case "SKIP", "SKIPPED": if let block { store.checkIn(block, built: false) }
            case "BUILT": if let block { store.checkIn(block, built: true) }
            case "DONE": if let nudge { store.completeNudge(nudge) }
            case "SNOOZE": if let nudge { store.snoozeNudge(nudge) }
            default: break
            }
        }
    }
}
