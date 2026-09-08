import AppKit
import CallNotesCore
import SwiftUI
import UniformTypeIdentifiers

struct HistorySplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedCallID) {
                if model.calls.isEmpty {
                    empty
                } else {
                    ForEach(model.calls) { call in
                        HistoryRow(call: call, notesTitle: model.notesByCall[call.id]?.body.title)
                            .tag(call.id)
                    }
                }
            }
            .navigationTitle("Calls")
            .safeAreaInset(edge: .bottom) {
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } detail: {
            if model.selectedCall != nil {
                CallDetailView(model: model)
            } else {
                empty
            }
        }
        .onChange(of: model.selectedCallID) { _, newValue in
            if let call = model.calls.first(where: { $0.id == newValue }) {
                Task { await model.select(call) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 40))
                .foregroundStyle(CallNotesStyle.primary)
            Text("No calls yet.")
                .font(.headline)
            Text("Take a call on your Mac or share a recording from your iPhone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Load sample call") {
                Task { await model.processSampleCall() }
            }
            .disabled(!model.canProcessSampleCall)
            .buttonStyle(.borderedProminent)
            .tint(CallNotesStyle.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct HistoryRow: View {
    var call: Call
    var notesTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notesTitle ?? call.counterpartyName ?? "Untitled call")
                .font(.headline)
            HStack {
                Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = call.durationSec {
                    Text("\(duration)s")
                }
                if call.sttProvider == .metaMuse {
                    Image(systemName: "cloud")
                        .accessibilityLabel("Cloud transcription")
                }
                Text(call.sttProvider == .metaMuse ? "Meta" : "Local")
                    .foregroundStyle(CallNotesStyle.primary)
                Text(call.status.rawValue.replacingOccurrences(of: "_", with: " "))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct CallDetailView: View {
    var model: AppModel
    @AppStorage("meta_privacy_acknowledged") private var privacyAcknowledged = false
    @State private var showMetaDisclosure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notes
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.selectedTurns) { turn in
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(turn.channel == .near ? CallNotesStyle.primary : CallNotesStyle.cloud)
                                .frame(width: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(turn.speakerName)
                                        .font(.caption.weight(.semibold))
                                    if turn.isProvisional {
                                        Text("provisional")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(timestamp(turn.start))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(turn.text)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            LivePillView(
                state: model.live,
                recordingState: model.recordingState,
                onStop: { Task { await model.stopLiveSession() } }
            )
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .confirmationDialog(
            "Send audio to Meta?",
            isPresented: $showMetaDisclosure,
            titleVisibility: .visible
        ) {
            Button("Re-transcribe with Meta") {
                privacyAcknowledged = true
                Task { await model.retranscribeSelectedCall(withMeta: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio for this call will be sent to Meta for transcription. Local transcription remains available if Meta fails.")
        }
    }

    @ViewBuilder
    private var header: some View {
        if let call = model.selectedCall {
            VStack(alignment: .leading, spacing: 6) {
                Text(call.counterpartyName ?? "Untitled call")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 12) {
                    Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(call.source.rawValue.replacingOccurrences(of: "_", with: " "))
                    Label(
                        call.sttProvider == .appleSpeech ? "Local" : "Meta (cloud)",
                        systemImage: call.sttProvider == .metaMuse ? "cloud" : "desktopcomputer"
                    )
                    if model.lastDERCallID == call.id, let der = model.lastDER {
                        Text(String(format: "DER %.1f%%", der.der * 100))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Menu("Re-transcribe with") {
                    Button("Local") {
                        Task { await model.retranscribeSelectedCall(withMeta: false) }
                    }
                    Button("Meta") {
                        if privacyAcknowledged {
                            Task { await model.retranscribeSelectedCall(withMeta: true) }
                        } else {
                            showMetaDisclosure = true
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let record = model.selectedNotes {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.body.title)
                    .font(.title3.weight(.semibold))
                Text(record.body.summary)
                    .foregroundStyle(.secondary)
                if model.isGeneratingNotes {
                    Text("Notes generating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                notesLists(record.body)
                HStack(spacing: 12) {
                    Button("Regenerate") {
                        Task { await model.regenerateNotes() }
                    }
                    .disabled(model.isGeneratingNotes)
                    Button("Export Markdown") {
                        exportMarkdown()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CallNotesStyle.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if model.isGeneratingNotes {
            Text("Notes generating...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func notesLists(_ notes: CallNotes) -> some View {
        if !notes.decisions.isEmpty {
            labeledList("Decisions", notes.decisions)
        }
        if !notes.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Action items")
                    .font(.caption.weight(.semibold))
                ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { _, item in
                    Text(actionLine(item))
                        .font(.caption)
                }
            }
        }
        if !notes.followUps.isEmpty {
            labeledList("Follow-ups", notes.followUps)
        }
        if !notes.openQuestions.isEmpty {
            labeledList("Open questions", notes.openQuestions)
        }
    }

    private func labeledList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.caption)
            }
        }
    }

    private func actionLine(_ item: CallNotes.ActionItem) -> String {
        var line = "• "
        if let owner = item.owner, !owner.isEmpty {
            line += "\(owner): "
        }
        line += item.text
        if let due = item.due, !due.isEmpty {
            line += " (due \(due))"
        }
        return line
    }

    private func exportMarkdown() {
        guard let call = model.selectedCall,
            let markdown = model.notesMarkdown(for: call.id)
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(call.counterpartyName ?? "call")-notes.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
