import CallNotesCore
import SwiftUI

struct ImportProgressView: View {
    var progress: ImportProgress
    var onDismiss: ((UUID) -> Void)?

    var body: some View {
        if !progress.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleJobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: icon(for: job.stage))
                                .foregroundStyle(color(for: job.stage))
                            Text(job.statusLine)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Spacer()
                            if job.stage.isTerminal, let onDismiss {
                                Button {
                                    onDismiss(job.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Dismiss")
                                .accessibilityLabel("Dismiss \(job.fileName)")
                            }
                        }
                        if job.stage == .transcribing || job.stage == .stitching || job.stage == .notes
                            || job.stage == .copying
                        {
                            ProgressView(value: min(max(job.fractionComplete, 0.02), 1))
                                .tint(CallNotesStyle.primary)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CallNotesStyle.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progress.activeJobs.first?.statusLine ?? "Import")
        }
    }

    private var visibleJobs: [ImportJob] {
        let active = progress.activeJobs
        if !active.isEmpty { return active }
        return Array(progress.jobs.suffix(2))
    }

    private func icon(for stage: ImportStage) -> String {
        switch stage {
        case .waiting, .settling: "tray.and.arrow.down"
        case .copying: "doc.on.doc"
        case .transcribing, .stitching: "waveform"
        case .notes: "note.text"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .duplicate: "arrow.triangle.2.circlepath"
        }
    }

    private func color(for stage: ImportStage) -> Color {
        switch stage {
        case .failed: CallNotesStyle.recording
        case .completed: CallNotesStyle.primary
        case .duplicate: .secondary
        default: CallNotesStyle.cloud
        }
    }
}
