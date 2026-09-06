import CallNotesCore
import EventKit
import Foundation

/// Optional EventKit arm: a calendar event with a phone/FaceTime link
/// starting within +/- 2 minutes lowers auto-start debounce to 1 s.
struct CalendarArmSignal: Sendable {
    var window: TimeInterval = 120

    func isArmed(now: Date = Date(), store: EKEventStore = EKEventStore()) -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return false }

        let start = now.addingTimeInterval(-window)
        let end = now.addingTimeInterval(window)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events.contains { event in
            let parts = [event.url?.absoluteString, event.notes, event.location, event.title]
            return parts.contains { text in
                guard let text else { return false }
                return CallAppNameMatcher.isCallLink(text)
            }
        }
    }

    func requestAccessIfNeeded() async {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
    }
}