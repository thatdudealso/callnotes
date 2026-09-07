import CallNotesCore
import EventKit
import Foundation

/// Optional EventKit arm: a calendar event with a phone/FaceTime link
/// starting within +/- 2 minutes lowers auto-start debounce to 1 s.
@MainActor
final class CalendarArmSignal {
    var window: TimeInterval = 120
    private let store: EKEventStore
    private var cachedArmed = false
    private var cacheExpiresAt = Date.distantPast

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func isArmed(now: Date = Date()) -> Bool {
        guard now >= cacheExpiresAt else { return cachedArmed }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            cachedArmed = false
            cacheExpiresAt = now.addingTimeInterval(30)
            return false
        }

        let start = now.addingTimeInterval(-window)
        let end = now.addingTimeInterval(window)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        cachedArmed = events.contains { event in
            let parts = [event.url?.absoluteString, event.notes, event.location, event.title]
            return parts.contains { text in
                guard let text else { return false }
                return CallAppNameMatcher.isCallLink(text)
            }
        }
        cacheExpiresAt = now.addingTimeInterval(30)
        return cachedArmed
    }

    func requestAccessIfNeeded() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
            cacheExpiresAt = .distantPast
        }
    }
}
