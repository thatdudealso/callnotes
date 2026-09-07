import Foundation

/// Versioned deep-notes prompt loaded from `Notes/Prompts/call_notes.md`.
public struct NotesPromptTemplate: Sendable, Equatable {
    public static let version = "call_notes.v1"

    public var source: String

    public init(source: String) {
        self.source = source
    }

    public static func load() -> NotesPromptTemplate {
        if let url = Bundle.module.url(forResource: "call_notes", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        {
            return NotesPromptTemplate(source: text)
        }
        return NotesPromptTemplate(source: embedded)
    }

    public func render(dialogue: String, counterparty: String?) -> String {
        source
            .replacingOccurrences(of: "{{COUNTERPARTY}}", with: counterparty ?? "unknown")
            .replacingOccurrences(of: "{{DIALOGUE}}", with: dialogue)
    }

    public func repairPrompt(invalidJSON: String, error: String) -> String {
        """
        The previous JSON failed validation: \(error)

        Invalid output:
        \(invalidJSON)

        Return a corrected JSON object that matches the call-notes schema. JSON only.
        """
    }

    public func mapChunkPrompt(dialogue: String, index: Int, total: Int, counterparty: String?) -> String {
        """
        This is chunk \(index + 1) of \(total) of a long call transcript.
        Extract partial structured notes for this window only. Return JSON matching the call-notes schema.
        Counterparty: \(counterparty ?? "unknown")

        \(dialogue)
        """
    }

    public func reducePrompt(partialJSON: [String], counterparty: String?) -> String {
        """
        Merge these partial call-notes JSON objects into one final object matching the call-notes schema.
        Deduplicate decisions, action items, follow-ups, questions, and entities.
        Keep a single title and a coherent summary. JSON only.
        Counterparty: \(counterparty ?? "unknown")

        \(partialJSON.enumerated().map { "Partial \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        """
    }

    static let embedded = """
        # Call notes

        You extract structured notes from a business-call transcript.
        Return ONLY a JSON object that matches the call-notes schema. No markdown fences.

        Counterparty: {{COUNTERPARTY}}

        Transcript:
        {{DIALOGUE}}
        """
}
