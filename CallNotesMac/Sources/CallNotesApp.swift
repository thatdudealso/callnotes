import CallNotesCore
import SwiftUI

/// Menu-bar CallNotes app. Phase 1 wires detection + two-channel capture;
/// transcription and notes arrive in later phases.
@main
struct CallNotesApp: App {
    @State private var coordinator = CaptureCoordinator()

    var body: some Scene {
        MenuBarExtra("CallNotes", systemImage: coordinator.recordingState.systemImage) {
            MenuBarContentView(coordinator: coordinator)
        }

        Window("CallNotes", id: "main") {
            HistoryWindowView()
        }
    }
}

struct MenuBarContentView: View {
    @Bindable var coordinator: CaptureCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button(coordinator.recordingState == .recording || coordinator.recordingState == .processing ? "Stop" : "Record Now") {
                coordinator.toggleManual()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open CallNotes") {
                openWindow(id: "main")
                NSApp.activate()
            }
            if let error = coordinator.lastError {
                Text(error)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Quit CallNotes") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            coordinator.start()
        }
    }
}

struct HistoryWindowView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No calls yet.")
                .font(.headline)
            Text("Take a call on your Mac or share a recording from your iPhone.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
