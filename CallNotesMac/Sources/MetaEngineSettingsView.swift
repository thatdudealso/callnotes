import CallNotesCore
import SwiftUI

struct MetaEngineSettingsView: View {
    @Bindable var appModel: AppModel
    @AppStorage("default_engine") private var defaultEngine = "local"
    @AppStorage("meta_zdr_enabled") private var zeroDataRetention = true
    @AppStorage("meta_privacy_acknowledged") private var privacyAcknowledged = false
    @State private var apiKey = ""
    @State private var keyStored = false
    @State private var showMetaDisclosure = false
    @State private var keyError: String?

    var body: some View {
        Form {
            Section("Default engine") {
                Picker("Transcribe new calls with", selection: engineBinding) {
                    Label("Local", systemImage: "desktopcomputer").tag("local")
                    Label("Meta", systemImage: "cloud").tag("meta")
                }
                .pickerStyle(.segmented)
                Text(defaultEngine == "meta"
                    ? "Meta sends mixed call audio to Meta for cloud transcription. Local remains the automatic fallback."
                    : "Local keeps call audio on this Mac. You can choose Meta for an individual call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meta Model API") {
                SecureField(keyStored ? "New API key (stored key is hidden)" : "Meta Model API key", text: $apiKey)
                    .textContentType(.password)
                HStack {
                    Button(keyStored ? "Replace Key" : "Save Key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keyStored {
                        Text("Stored in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { removeKey() }
                    }
                }
                Toggle("Zero-data retention", isOn: $zeroDataRetention)
                Text("Enabled by default. CallNotes sends `zdrOverride: true` on every Meta realtime handshake. Meta's file endpoint does not accept a ZDR request field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Cost meter") {
                LabeledContent("Billed Meta audio", value: appModel.metaBilledDuration)
                LabeledContent("Estimated cost", value: appModel.metaCost)
                Text("$0.18/hour, based on Meta's whole seconds of processed audio. Failed-before-transcript and rate-limited requests are not billed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 430)
        .onAppear(perform: loadKeyStatus)
        .confirmationDialog(
            "Send audio to Meta?",
            isPresented: $showMetaDisclosure,
            titleVisibility: .visible
        ) {
            Button("Use Meta") {
                privacyAcknowledged = true
                defaultEngine = "meta"
            }
            Button("Keep Local", role: .cancel) {
                defaultEngine = "local"
            }
        } message: {
            Text("Audio for this call will be sent to Meta for transcription. Local transcription remains available if Meta fails.")
        }
    }

    private var engineBinding: Binding<String> {
        Binding(
            get: { defaultEngine },
            set: { newValue in
                if newValue == "meta" && !privacyAcknowledged {
                    showMetaDisclosure = true
                } else {
                    defaultEngine = newValue
                }
            }
        )
    }

    private func loadKeyStatus() {
        do {
            keyStored = try MetaAPIKeyKeychain.load() != nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try MetaAPIKeyKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKey = ""
            keyStored = true
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try MetaAPIKeyKeychain.remove()
            keyStored = false
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}
