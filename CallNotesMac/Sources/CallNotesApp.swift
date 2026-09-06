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
                recordingState: model.recordingState,
                onStop: {
                    Task { await model.stopLiveSession() }
                    stopCapture()
                }
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
            Button(model.recordingState == .recording ? "Stop" : "Record Now") {
                if model.recordingState == .recording {
                    Task { await model.stopLiveSession() }
                    stopCaptureIfNeeded()
                } else {
                    coordinator.toggleManual()
                    Task {
                        do {
                            try await model.startLiveSession()
                        } catch {
                            model.statusMessage = error.localizedDescription
                        }
                    }
                    openWindow(id: "pill")
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Load sample call") {
                openWindow(id: "main")
                openWindow(id: "pill")
                Task { await model.processSampleCall() }
            }
            .disabled(!model.canProcessSampleCall)
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

    private func stopCaptureIfNeeded() {
        guard coordinator.recordingState == .recording || coordinator.recordingState == .processing else { return }
        coordinator.toggleManual()
    }
}
