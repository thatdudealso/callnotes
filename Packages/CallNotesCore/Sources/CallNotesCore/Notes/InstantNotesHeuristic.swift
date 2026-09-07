import Foundation

/// Deterministic title + tl;dr used when Apple Foundation Models are unavailable
/// so the history list is never blank at hang-up.
public enum InstantNotesHeuristic {
    public static func notes(from transcript: Transcript, counterparty: String?) -> CallNotes {
        let dialogue = transcript.dialogueText()
        let title: String
        if let counterparty, !counterparty.isEmpty {
            title = "\(counterparty) call"
        } else if let first = transcript.segments.first(where: { !$0.text.isEmpty }) {
            title = String(first.text.prefix(48))
        } else {
            title = "Untitled call"
        }
        let summary = tldr(from: dialogue)
        return CallNotes(title: title, summary: summary)
    }

    private static func tldr(from dialogue: String) -> String {
        let collapsed = dialogue.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "No transcript text yet." }
        if collapsed.count <= 280 { return collapsed }
        return String(collapsed.prefix(277)) + "..."
    }
}
