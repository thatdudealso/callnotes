import Foundation

/// Renders persisted `CallNotes` as Markdown for export.
public enum NotesMarkdown {
    public static func render(_ notes: CallNotes) -> String {
        var parts: [String] = ["# \(notes.title)", "", notes.summary]
        if !notes.decisions.isEmpty {
            parts.append(contentsOf: ["", "## Decisions"] + notes.decisions.map { "- \($0)" })
        }
        if !notes.actionItems.isEmpty {
            parts.append(contentsOf: ["", "## Action items"] + notes.actionItems.map(actionLine))
        }
        if !notes.followUps.isEmpty {
            parts.append(contentsOf: ["", "## Follow-ups"] + notes.followUps.map { "- \($0)" })
        }
        if !notes.openQuestions.isEmpty {
            parts.append(contentsOf: ["", "## Open questions"] + notes.openQuestions.map { "- \($0)" })
        }
        let entityLines = entitySection(notes.entities)
        if !entityLines.isEmpty {
            parts.append(contentsOf: ["", "## Entities"] + entityLines)
        }
        return parts.joined(separator: "\n") + "\n"
    }

    private static func actionLine(_ item: CallNotes.ActionItem) -> String {
        var line = "- "
        if let owner = item.owner, !owner.isEmpty {
            line += "\(owner): "
        }
        line += item.text
        if let due = item.due, !due.isEmpty {
            line += " (due \(due))"
        }
        return line
    }

    private static func entitySection(_ entities: CallNotes.Entities) -> [String] {
        var lines: [String] = []
        if !entities.people.isEmpty { lines.append("- People: \(entities.people.joined(separator: ", "))") }
        if !entities.companies.isEmpty {
            lines.append("- Companies: \(entities.companies.joined(separator: ", "))")
        }
        if !entities.amounts.isEmpty { lines.append("- Amounts: \(entities.amounts.joined(separator: ", "))") }
        if !entities.dates.isEmpty { lines.append("- Dates: \(entities.dates.joined(separator: ", "))") }
        return lines
    }
}
