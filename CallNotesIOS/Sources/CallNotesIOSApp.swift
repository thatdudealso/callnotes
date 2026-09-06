import CallNotesCore
import SwiftUI

/// Phase 0 stub of the CallNotes iOS app: the three-tab shell from plan
/// section 10.2. Share ingestion, pairing, and sync arrive in Phase 6.
@main
struct CallNotesIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Calls", systemImage: "list.bullet.rectangle") {
                CallsPlaceholderView()
            }
            Tab("Record", systemImage: "record.circle") {
                RecordPlaceholderView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsPlaceholderView()
            }
        }
    }
}

struct CallsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "No calls yet",
            systemImage: "phone.badge.waveform",
            description: Text("Share a call recording from Notes, or record an in-person meeting.")
        )
    }
}

struct RecordPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "In-person recording",
            systemImage: "record.circle",
            description: Text("Meeting capture arrives in a later phase.")
        )
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Not paired",
            systemImage: "laptopcomputer.and.iphone",
            description: Text("Pairing with your Mac arrives in a later phase.")
        )
    }
}
