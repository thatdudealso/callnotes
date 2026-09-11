import AppKit
import CallNotesCore
import SwiftUI

@main
struct CallNotesApp: App {
    @State private var coordinator = CaptureCoordinator()
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("CallNotes", image: coordinator.recordingState.menuBarImage) {
            MenuBarContentView(coordinator: coordinator, model: model)
        }

        Window("CallNotes", id: "main") {
            OnboardingGate(model: model)
        }

        Window("Live", id: "pill") {
            LivePillView(
                state: model.live,
                recordingState: model.recordingState,
                onStop: {
                    Task { await model.stopLiveSession() }
                }
            )
            .padding(8)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            TabView {
                MetaEngineSettingsView(appModel: model)
                    .tabItem { Label("Engines", systemImage: "cpu") }
                DevicesSettingsView(appModel: model)
                    .tabItem { Label("Devices", systemImage: "iphone") }
            }
        }
    }

}

struct MenuBarContentView: View {
    @Bindable var coordinator: CaptureCoordinator
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("engine_for_next_call") private var engineForNextCall = "default"
    @AppStorage("meta_privacy_acknowledged") private var privacyAcknowledged = false
    @State private var showMetaDisclosure = false

    var body: some View {
        Group {
            Button(model.recordingState == .recording ? "Stop" : "Record Now") {
                if model.recordingState == .recording {
                    Task { await model.stopLiveSession() }
                } else {
                    Task {
                        do {
                            let override: STTProviderID? = switch engineForNextCall {
                            case "meta": .metaMuse
                            case "local": .appleSpeech
                            default: nil
                            }
                            try await model.startLiveSession(override: override)
                            coordinator.toggleManual()
                        } catch {
                            model.statusMessage = error.localizedDescription
                        }
                    }
                    openWindow(id: "pill")
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.recordingState != .recording && !model.canStartLiveSession)
            Button("Load sample call") {
                openWindow(id: "main")
                openWindow(id: "pill")
                Task { await model.processSampleCall() }
            }
            .disabled(!model.canProcessSampleCall)
            Button("Open Inbox folder") {
                model.revealInbox()
            }
            Menu("Engine for next call") {
                Button("Default") { engineForNextCall = "default" }
                Button("Local") { engineForNextCall = "local" }
                Button("Meta") {
                    if privacyAcknowledged {
                        engineForNextCall = "meta"
                    } else {
                        showMetaDisclosure = true
                    }
                }
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
            coordinator.setPCMHandler { pcm in
                Task { @MainActor in
                    try? await model.appendLivePCM(pcm)
                }
            }
            model.setCaptureStopHandler {
                await coordinator.stopLiveCapture()
            }
            coordinator.setCaptureFailureHandler { message in
                await model.failLiveSessionForCapture(message)
            }
            coordinator.start()
        }
        .confirmationDialog(
            "Send audio to Meta?",
            isPresented: $showMetaDisclosure,
            titleVisibility: .visible
        ) {
            Button("Use Meta") {
                privacyAcknowledged = true
                engineForNextCall = "meta"
            }
            Button("Keep Local", role: .cancel) {
                engineForNextCall = "local"
            }
        } message: {
            Text("Audio for this call will be sent to Meta for transcription. Local transcription remains available if Meta fails.")
        }
    }
}

struct OnboardingGate: View {
    @Bindable var model: AppModel
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    var body: some View {
        Group {
            if onboardingComplete {
                HistorySplitView(model: model)
                    .frame(minWidth: 800, minHeight: 520)
            } else {
                SetupWizardView {
                    onboardingComplete = true
                }
            }
        }
    }
}
