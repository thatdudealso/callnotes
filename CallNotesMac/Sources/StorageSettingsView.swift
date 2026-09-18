import AppKit
import CallNotesCore
import SwiftUI
import UniformTypeIdentifiers

struct StorageSettingsView: View {
    @Bindable var appModel: AppModel
    @AppStorage(RetentionPolicy.modeDefaultsKey) private var retentionMode = RetentionPolicy.Mode.keepForever.rawValue
    @AppStorage(RetentionPolicy.daysDefaultsKey) private var retentionDays = RetentionPolicy.keepForeverSentinel
    @State private var backupMessage: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Retention") {
                Picker("Recordings", selection: $retentionMode) {
                    Text("Keep forever").tag(RetentionPolicy.Mode.keepForever.rawValue)
                    Text("Delete audio, keep transcript").tag(RetentionPolicy.Mode.deleteAudioKeepTranscript.rawValue)
                    Text("Delete audio and notes").tag(RetentionPolicy.Mode.deleteAll.rawValue)
                }
                if retentionMode != RetentionPolicy.Mode.keepForever.rawValue {
                    Stepper(value: $retentionDays, in: 1...3650) {
                        Text("After \(max(retentionDays, 1)) days")
                    }
                }
                Text("Deletion removes the recording file from disk, not only the row in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sweep now") {
                    Task { await runSweep() }
                }
                .disabled(isWorking)
            }

            Section("Backups") {
                Text("pg_dump of the dedicated CallNotes Postgres instance (port 5433). A backup you have never restored is not a backup - Verify restore dumps, restores into a scratch database, and compares row counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Back up database") {
                        Task { await runBackup(verify: false) }
                    }
                    .disabled(isWorking)
                    Button("Back up and verify restore") {
                        Task { await runBackup(verify: true) }
                    }
                    .disabled(isWorking)
                }
            }

            Section("Diagnostics") {
                Text("Exports recent logs, redacted settings, and provider health. The bundle never includes call audio, transcript text, notes, API keys, device tokens, or database passwords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Export diagnostics bundle") {
                    exportDiagnostics()
                }
                .disabled(isWorking)
            }

            if let backupMessage {
                Section {
                    Text(backupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 460)
        .onChange(of: retentionMode) { _, mode in
            if mode != RetentionPolicy.Mode.keepForever.rawValue, retentionDays <= 0 {
                retentionDays = 30
            }
        }
    }

    private func runSweep() async {
        isWorking = true
        defer { isWorking = false }
        let result = await appModel.sweepRetention()
        if let result {
            backupMessage = "Removed \(result.deletedAudioPaths.count) recordings, \(result.reclaimedBytes) bytes."
        }
    }

    private func runBackup(verify: Bool) async {
        isWorking = true
        defer { isWorking = false }
        backupMessage = await appModel.backupDatabase(verify: verify)
    }

    private func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the diagnostics bundle."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            backupMessage = await appModel.exportDiagnostics(to: directory)
        }
    }
}
