import CallNotesCore
import SwiftUI

struct HistorySplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedCallID) {
                if model.calls.isEmpty {
                    empty
                } else {
                    ForEach(model.calls) { call in
                        HistoryRow(call: call)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(call.counterpartyName ?? "Untitled call")
                .font(.headline)
            HStack {
                Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = call.durationSec {
                    Text("\(duration)s")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
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
                    Text(call.sttProvider == .appleSpeech ? "Local" : call.sttProvider.rawValue)
                    if let der = model.lastDER {
                        Text(String(format: "DER %.1f%%", der.der * 100))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
