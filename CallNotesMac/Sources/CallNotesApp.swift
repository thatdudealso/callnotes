import AppKit
import CallNotesCore
import SwiftUI

@main
struct CallNotesApp: App {
    @State private var coordinator = CaptureCoordinator()
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("CallNotes", systemImage: coordinator.recordingState.systemImage) {
            MenuBarContentView(coordinator: coordinator, model: model)
        }

        Window("CallNotes", id: "main") {
            HistorySplitView(model: model)
                .frame(minWidth: 720, minHeight: 420)
        }

        Window("Live", id: "pill") {
            LivePillView(
                state: model.live,
                recordingState: coordinator.recordingState,
                onStop: stopCapture
            )
            .padding(8)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    private func stopCapture() {
        guard coordinator.recordingState == .recording || coordinator.recordingState == .processing else { return }
        coordinator.toggleManual()
    }
}

struct MenuBarContentView: View {
    @Bindable var coordinator: CaptureCoordinator
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button(coordinator.recordingState == .recording || coordinator.recordingState == .processing ? "Stop" : "Record Now") {
                coordinator.toggleManual()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Load sample call") {
                openWindow(id: "main")
                openWindow(id: "pill")
                Task { await model.processSampleCall() }
            }
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
