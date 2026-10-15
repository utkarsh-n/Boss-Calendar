import EventKit
import Foundation

/// A busy commitment read from Apple Calendar (read-only).
struct BusyEvent: Sendable, Hashable, Identifiable {
    var id: String { "\(title)|\(start.timeIntervalSinceReferenceDate)" }
    var title: String
    var start: Date
    var end: Date
    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

/// EventKit access lives on its own actor; only Sendable values cross back to the main actor.
actor CalendarBridge {
    enum Access: Sendable, Equatable {
        case notDetermined, granted, denied
    }

    private let store = EKEventStore()

    func access() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Access {
        do {
            return try await store.requestFullAccessToEvents() ? .granted : .denied
        } catch {
            return .denied
        }
    }

    /// Timed events that mark you busy. All-day and "free" events don't block build time.
    func events(from start: Date, to end: Date) -> [BusyEvent] {
        guard access() == .granted else { return [] }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && $0.status != .canceled }
            .map { BusyEvent(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
    }
}
