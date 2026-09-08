//
//  SetupWizardView.swift
//  CallNotesMac
//
//  Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone),
//  MIT License:
//    Copyright (c) 2026 Kuber Mehta (Megaphone)
//    Copyright (c) 2026 Zach Latta (FreeFlow)
//  See THIRD_PARTY.md for the full license text and the per-component
//  reuse decision. Adapted for CallNotes: kept the card-flow chrome (step
//  container, footer navigation, dot indicator, permission rows, option
//  rows) and the microphone plus screen/system-audio permission cards with
//  the TCC re-grant guidance and "continue anyway" escape hatch; removed
//  unrelated input-capture, text-delivery, launch-at-login, model-availability,
//  overlay, vocabulary, transcription-test, and promotion features; re-sequenced the steps for CallNotes (welcome,
//  microphone, system audio, voice enrollment, phone setup, storage check,
//  engine choice, consent policy, pair iPhone); replaced the global app
//  state object with a local permissions model; all user-facing strings now
//  say CallNotes.
//

import SwiftUI
import AVFoundation
import AppKit
import CoreGraphics

/// Local, self-contained permission state for the setup wizard.
/// Deliberately not a global app state object.
@MainActor
final class SetupWizardModel: ObservableObject {
    @Published var micPermissionGranted = false
    @Published var systemAudioPermissionGranted = false

    private var systemAudioTimer: Timer?

    func refreshMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micPermissionGranted = granted
            }
        }
    }

    func refreshSystemAudioPermission() {
        systemAudioPermissionGranted = CGPreflightScreenCaptureAccess()
    }

    func requestSystemAudioPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// TCC has no change notification for this permission, so poll while the
    /// system-audio step is visible (mirrors the vendored setup flow).
    func startSystemAudioPolling() {
        systemAudioTimer?.invalidate()
        systemAudioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSystemAudioPermission()
            }
        }
    }

    func stopSystemAudioPolling() {
        systemAudioTimer?.invalidate()
        systemAudioTimer = nil
    }

    func openSystemAudioSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

struct SetupWizardView: View {
    var onComplete: () -> Void

    private enum SetupStep: Int, CaseIterable {
        case welcome = 0
        case microphone
        case systemAudio
        case voiceEnrollment
        case phoneSetup
        case storageCheck
        case engineChoice
        case consentPolicy
        case pairPhone
    }

    @StateObject private var model = SetupWizardModel()
    @State private var currentStep = SetupStep.welcome
    @AppStorage("default_engine") private var defaultEngine = "local"
    @AppStorage("meta_zdr_enabled") private var metaZDREnabled = true
    @AppStorage("meta_privacy_acknowledged") private var metaPrivacyAcknowledged = false
    @AppStorage("consent_policy") private var consentPolicy = "announce"
    @State private var metaAPIKey = ""
    @State private var metaKeyStored = false
    @State private var showMetaDisclosure = false
    @State private var metaKeyError: String?

    private let totalSteps: [SetupStep] = SetupStep.allCases

    var body: some View {
        VStack(spacing: 0) {
            currentStepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 32)

            Divider()

            ZStack {
                stepIndicator

                HStack(alignment: .center) {
                    Group {
                        if currentStep != .welcome {
                            Button("Back") {
                                withAnimation {
                                    currentStep = previousStep(currentStep)
                                }
                            }
                        }
                    }

                    Spacer()

                    Group {
                        if currentStep != .pairPhone {
                            HStack(spacing: 10) {
                                // Escape hatch for the permission steps: TCC can
                                // pin a grant to a previous build (ad-hoc signing),
                                // leaving the toggle ON while detection says no.
                                // Never hard-block setup on that.
                                if currentStep == .systemAudio && !canContinueFromCurrentStep {
                                    Button("Continue anyway") {
                                        withAnimation {
                                            currentStep = nextStep(currentStep)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }

                                Button("Continue") {
                                    withAnimation {
                                        currentStep = nextStep(currentStep)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canContinueFromCurrentStep)
                            }
                        } else {
                            Button("Get Started") {
                                onComplete()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 520, height: 680)
        .onAppear {
            model.refreshMicPermission()
            model.refreshSystemAudioPermission()
            metaKeyStored = (try? MetaAPIKeyKeychain.load()) != nil
        }
        .onDisappear {
            model.stopSystemAudioPolling()
        }
        .confirmationDialog(
            "Send audio to Meta?",
            isPresented: $showMetaDisclosure,
            titleVisibility: .visible
        ) {
            Button("Use Meta") {
                metaPrivacyAcknowledged = true
                defaultEngine = "meta"
            }
            Button("Keep Local", role: .cancel) {
                defaultEngine = "local"
            }
        } message: {
            Text("Audio for this call will be sent to Meta for transcription. Local transcription remains available if Meta fails.")
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .microphone:
            microphoneStep
        case .systemAudio:
            systemAudioStep
        case .voiceEnrollment:
            placeholderStep(
                icon: "person.wave.2.fill",
                title: "Voice Enrollment",
                description: "Teach CallNotes your voice so it can tell who said what in a call."
            )
        case .phoneSetup:
            placeholderStep(
                icon: "phone.badge.checkmark",
                title: "Phone Setup",
                description: "A short checklist to route your iPhone calls through this Mac."
            )
        case .storageCheck:
            placeholderStep(
                icon: "internaldrive.fill",
                title: "Storage Check",
                description: "Verify Postgres, Ollama, and the local models CallNotes depends on."
            )
        case .engineChoice:
            engineChoiceStep
        case .consentPolicy:
            consentPolicyStep
        case .pairPhone:
            pairPhoneStep
        }
    }

    // MARK: - Steps

    var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)

            VStack(spacing: 6) {
                Text("Welcome to CallNotes")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("Record, transcribe, and summarize your calls.\nEverything stays on your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Microphone Access")
                .font(.title)
                .fontWeight(.bold)

            Text("CallNotes needs access to your microphone to record your side of a call for transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "mic.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Microphone")
                Spacer()
                if model.micPermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        model.requestMicPermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .onAppear {
            model.refreshMicPermission()
        }
    }

    var systemAudioStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("System Audio Recording")
                .font(.title)
                .fontWeight(.bold)

            Text("CallNotes captures the other side of your calls through macOS system audio. macOS groups this under Screen & System Audio Recording — CallNotes only captures audio, never your screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "waveform")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Screen & System Audio Recording")
                Spacer()
                if model.systemAudioPermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        model.requestSystemAudioPermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            if !model.systemAudioPermissionGranted {
                Text("Already enabled but stuck here? After an update, macOS can pin the old permission to the previous version. In System Settings → Privacy & Security → Screen & System Audio Recording, remove CallNotes with the − button, then add it back.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open System Settings") {
                    model.openSystemAudioSettings()
                }
            }
        }
        .onAppear {
            model.refreshSystemAudioPermission()
            model.startSystemAudioPolling()
        }
        .onDisappear {
            model.stopSystemAudioPolling()
        }
    }

    var engineChoiceStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Default Engine")
                .font(.title)
                .fontWeight(.bold)

            Text("Choose which engine CallNotes uses for transcription. You can change this later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                SetupChoiceRow(
                    title: "Local",
                    subtitle: "Runs entirely on this Mac with Postgres, Ollama, and local models. Nothing leaves your machine.",
                    icon: "desktopcomputer",
                    isSelected: defaultEngine == "local"
                ) {
                    defaultEngine = "local"
                }
                SetupChoiceRow(
                    title: "Meta",
                    subtitle: "Cloud transcription with Meta. Local transcription automatically takes over if Meta fails.",
                    icon: "cloud.fill",
                    isSelected: defaultEngine == "meta"
                ) {
                    if metaPrivacyAcknowledged {
                        defaultEngine = "meta"
                    } else {
                        showMetaDisclosure = true
                    }
                }
            }
            .padding(.top, 6)

            if defaultEngine == "meta" {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(metaKeyStored ? "New Meta Model API key (stored key is hidden)" : "Meta Model API key", text: $metaAPIKey)
                    HStack {
                        Button(metaKeyStored ? "Replace key" : "Save key") {
                            saveMetaKey()
                        }
                        .disabled(metaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if metaKeyStored {
                            Text("Stored in Keychain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Zero-data retention", isOn: $metaZDREnabled)
                    Text("CallNotes enables ZDR on every Meta realtime session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let metaKeyError {
                        Text(metaKeyError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private func saveMetaKey() {
        do {
            try MetaAPIKeyKeychain.save(metaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            metaAPIKey = ""
            metaKeyStored = true
            metaKeyError = nil
        } catch {
            metaKeyError = error.localizedDescription
        }
    }

    var consentPolicyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Consent Policy")
                .font(.title)
                .fontWeight(.bold)

            Text("Choose how CallNotes lets the other party know a call is being recorded. Recording-consent laws vary by region — pick what fits yours.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                SetupChoiceRow(
                    title: "Announce verbally",
                    subtitle: "CallNotes speaks a brief recording notice at the start of each call.",
                    icon: "speaker.wave.2.fill",
                    isSelected: consentPolicy == "announce"
                ) {
                    consentPolicy = "announce"
                }
                SetupChoiceRow(
                    title: "Play tone",
                    subtitle: "A short tone plays when recording starts.",
                    icon: "bell.fill",
                    isSelected: consentPolicy == "tone"
                ) {
                    consentPolicy = "tone"
                }
                SetupChoiceRow(
                    title: "Off",
                    subtitle: "No notice is given. You are responsible for obtaining consent where required.",
                    icon: "bell.slash.fill",
                    isSelected: consentPolicy == "off"
                ) {
                    consentPolicy = "off"
                }
            }
            .padding(.top, 6)
        }
    }

    var pairPhoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Pair iPhone")
                .font(.title)
                .fontWeight(.bold)

            Text("Link your iPhone so CallNotes can pick up calls automatically. Pairing arrives in a later build — CallNotes lives in your menu bar in the meantime.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                SetupHowToRow(icon: "mic.fill", text: "Your microphone is recorded locally")
                SetupHowToRow(icon: "waveform", text: "System audio captures the other side of the call")
                SetupHowToRow(icon: "doc.text.fill", text: "Transcripts and summaries land in your notes")
            }
            .padding(.top, 10)
        }
    }

    func placeholderStep(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text(title)
                .font(.title)
                .fontWeight(.bold)

            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Coming soon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }

    var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(totalSteps, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .microphone:
            return model.micPermissionGranted
        case .systemAudio:
            return model.systemAudioPermissionGranted
        default:
            return true
        }
    }

    // MARK: - Navigation

    private func previousStep(_ step: SetupStep) -> SetupStep {
        let previous = SetupStep(rawValue: step.rawValue - 1)
        return previous ?? .welcome
    }

    private func nextStep(_ step: SetupStep) -> SetupStep {
        let next = SetupStep(rawValue: step.rawValue + 1)
        return next ?? .pairPhone
    }
}

// MARK: - Card components

struct SetupHowToRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// Selectable option card used by the engine and consent steps.
struct SetupChoiceRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
