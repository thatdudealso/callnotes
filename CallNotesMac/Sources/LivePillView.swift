import CallNotesCore
import SwiftUI

struct LivePillView: View {
    var state: LiveTranscriptState
    var recordingState: RecordingState
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recordingState == .recording ? CallNotesStyle.recording : CallNotesStyle.primary)
                .frame(width: 8, height: 8)
            Text(timerText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            engineBadge
            Text(state.currentSpeakerName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.isProvisionalSpeaker ? .secondary : .primary)
            Text(state.lastLine.isEmpty ? "Waiting for speech..." : state.lastLine)
                .font(.caption)
                .lineLimit(1)
            Button("Stop", action: onStop)
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(CallNotesStyle.primary.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var timerText: String {
        let seconds = Int(state.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var engineBadge: some View {
        HStack(spacing: 4) {
            if state.isOffDevice {
                Image(systemName: "cloud")
                    .foregroundStyle(CallNotesStyle.cloud)
                Text("Meta (cloud)")
            } else {
                Text("Local")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(CallNotesStyle.primary.opacity(0.12), in: Capsule())
    }
}
