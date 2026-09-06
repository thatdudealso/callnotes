import CallNotesCore
import SwiftUI

/// Phase 0 stub of the CallNotes menu-bar app: launchable, shows the menu-bar
/// item and an empty history window. Capture, pipeline, and settings arrive
/// in Phases 1-3.
@main
struct CallNotesApp: App {
    @State private var recordingState = RecordingState.idle

    var body: some Scene {
        MenuBarExtra("CallNotes", systemImage: recordingState.systemImage) {
            MenuBarContentView(recordingState: $recordingState)
        }

        Window("CallNotes", id: "main") {
            HistoryWindowView()
        }
    }
}

/// Menu-bar icon states per plan section 10.1.
enum RecordingState {
    case idle
    case armed
    case recording
    case processing

    var systemImage: String {
        switch self {
        case .idle: return "phone.badge.waveform"
        case .armed: return "phone.badge.waveform.fill"
        case .recording: return "record.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        }
    }
}

struct MenuBarContentView: View {
    @Binding var recordingState: RecordingState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recordingState == .recording ? "Stop" : "Record Now") {
            // Capture engine arrives in Phase 1.
            recordingState = recordingState == .recording ? .idle : .recording
        }
        Button("Open CallNotes") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit CallNotes") {
            NSApp.terminate(nil)
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
