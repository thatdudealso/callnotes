import AppKit
import CallNotesCore
import Foundation

/// Observes running FaceTime / Phone apps and stores their bundle IDs.
/// Identifiers are never hardcoded: they are learned from `localizedName`
/// matching on first run and persisted in user defaults.
@MainActor
final class CallAppIdentityStore {
    static let defaultsKey = "observedCallAppBundleIDs"

    private let defaults: UserDefaults
    private(set) var bundleIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.defaultsKey) {
            bundleIDs = Set(stored)
        } else {
            bundleIDs = []
        }
    }

    func observe(_ apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications) {
        var discovered = false
        for app in apps {
            guard let name = app.localizedName, let id = app.bundleIdentifier else { continue }
            if CallAppNameMatcher.isCallAppDisplayName(name), !bundleIDs.contains(id) {
                bundleIDs.insert(id)
                discovered = true
            }
        }
        if discovered {
            persist()
        }
    }

    func contains(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    var hasObservedIDs: Bool { !bundleIDs.isEmpty }

    private func persist() {
        defaults.set(Array(bundleIDs).sorted(), forKey: Self.defaultsKey)
    }
}