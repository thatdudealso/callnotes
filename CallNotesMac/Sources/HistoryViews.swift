import AppKit
import CallNotesCore
import SwiftUI
import UniformTypeIdentifiers

struct HistorySplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                Label("Dashboard", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.dashboard)
                Section("Calls") {
                    if model.calls.isEmpty {
                        Text("No calls yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.calls) { call in
                            HistoryRow(call: call, notesTitle: model.notesByCall[call.id]?.body.title)
                                .tag(SidebarItem.call(call.id))
                        }
                    }
                }
            }
            .navigationTitle("CallNotes")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    ImportProgressView(progress: model.importProgress) { jobID in
                        model.dismissImportJob(jobID)
                    }
                    if let status = model.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } detail: {
            switch model.sidebarSelection {
            case .dashboard:
                DashboardView(model: model)
            case .call where model.selectedCall != nil:
                CallDetailView(model: model)
            default:
                empty
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
            Text("Take a call on your Mac, drop an m4a into the Inbox folder, or share a recording from your iPhone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Inbox folder") {
                model.revealInbox()
            }
            .buttonStyle(.bordered)
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
                Text(providerLabel(call.sttProvider))
                    .foregroundStyle(CallNotesStyle.primary)
                Text(call.status.displayName)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func providerLabel(_ provider: STTProviderID) -> String {
        switch provider {
        case .appleSpeech: "Local"
        case .fluidParakeet: "Parakeet"
        case .metaMuse: "Meta"
        }
    }
}

/// The draft lives here rather than in `AppModel.calls` so a store refresh that
/// lands mid-edit cannot rewrite what is being typed. The name is committed on
/// submit or focus loss, and an external change is only adopted while idle.
private struct CounterpartyNameField: View {
    var model: AppModel
    let call: Call

    @State private var draft: Draft?
    @FocusState private var isEditing: Bool

    /// The draft carries the call it belongs to and the name it started from, so a
    /// rebind to another call commits the edit to its own call instead of dropping
    /// it or writing it onto whatever is selected by then.
    private struct Draft {
        let callID: UUID
        var committedName: String
        var text: String

        var normalized: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var isDirty: Bool { normalized != committedName }
    }

    var body: some View {
        TextField(
            "Counterparty",
            text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 })
        )
        .textFieldStyle(.roundedBorder)
        .focused($isEditing)
        .onSubmit { commit() }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        .onChange(of: call.id) { _, _ in rebind() }
        .onDisappear { commit() }
        .onChange(of: call.counterpartyName) { _, name in
            guard !isEditing, let draft, draft.callID == call.id, !draft.isDirty else { return }
            self.draft = Draft(callID: call.id, committedName: name ?? "", text: name ?? "")
        }
        .task { rebind() }
    }

    @MainActor
    private func rebind() {
        guard draft?.callID != call.id else { return }
        commit()
        draft = Draft(
            callID: call.id,
            committedName: call.counterpartyName ?? "",
            text: call.counterpartyName ?? ""
        )
    }

    @MainActor
    private func commit() {
        guard let pending = draft, pending.isDirty else { return }
        draft?.committedName = pending.normalized
        Task { await model.updateCounterpartyName(for: pending.callID, name: pending.normalized) }
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
                Task { await model.retranscribeSelectedCall(with: .metaMuse) }
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
                CounterpartyNameField(model: model, call: call)
                HStack(spacing: 12) {
                    Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(call.source.rawValue.replacingOccurrences(of: "_", with: " "))
                    Label(
                        detailProviderLabel(call.sttProvider),
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
                        Task { await model.retranscribeSelectedCall(with: .appleSpeech) }
                    }
                    Button("Parakeet") {
                        Task { await model.retranscribeSelectedCall(with: .fluidParakeet) }
                    }
                    Button("Meta") {
                        if privacyAcknowledged {
                            Task { await model.retranscribeSelectedCall(with: .metaMuse) }
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

    private func detailProviderLabel(_ provider: STTProviderID) -> String {
        switch provider {
        case .appleSpeech: "Local"
        case .fluidParakeet: "Parakeet"
        case .metaMuse: "Meta (cloud)"
        }
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
