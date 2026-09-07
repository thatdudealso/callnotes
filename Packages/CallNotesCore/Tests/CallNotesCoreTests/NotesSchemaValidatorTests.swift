import Foundation
import Testing

@testable import CallNotesCore

@Suite struct NotesSchemaValidatorTests {
    let validator = NotesSchemaValidator()

    @Test func acceptsPlanSchemaJSON() throws {
        let notes = try validator.validate(Self.validJSON, kind: .deep)
        #expect(notes.title == "Acme - pricing follow-up")
        #expect(notes.actionItems.first?.owner == "Ashish")
        #expect(notes.entities.companies == ["Acme"])
    }

    @Test func extractsJSONFromMarkdownFence() throws {
        let fenced = """
            ```json
            \(Self.validJSON)
            ```
            """
        let notes = try validator.validate(fenced, kind: .deep)
        #expect(notes.title == "Acme - pricing follow-up")
    }

    @Test func rejectsEmptyTitle() {
        let json = """
            {"title":"","summary":"Discussed volume pricing.","decisions":[],"action_items":[],"follow_ups":[],"open_questions":[],"entities":{"people":[],"companies":[],"amounts":[],"dates":[]}}
            """
        #expect(throws: NotesGenerationError.self) {
            try validator.validate(json, kind: .deep)
        }
    }

    @Test func rejectsMissingActionItems() {
        let json = """
            {"title":"Acme","summary":"Discussed volume pricing.","decisions":[],"follow_ups":[],"open_questions":[],"entities":{"people":[],"companies":[],"amounts":[],"dates":[]}}
            """
        #expect(throws: NotesGenerationError.self) {
            try validator.validate(json, kind: .deep)
        }
    }

    @Test(arguments: ["top_level", "action_item", "entities"])
    func rejectsUnexpectedProperties(location: String) {
        let json: String
        switch location {
        case "action_item":
            json = Self.validJSON.replacingOccurrences(of: #""due": "2026-09-10""#, with: #""due": "2026-09-10", "extra": true"#)
        case "entities":
            json = Self.validJSON.replacingOccurrences(of: #""dates": []"#, with: #""dates": [], "extra": true"#)
        default:
            json = Self.validJSON.replacingOccurrences(of: #""title":"#, with: #""extra": true, "title":"#)
        }
        #expect(throws: NotesGenerationError.self) {
            try validator.validate(json, kind: .deep)
        }
    }

    @Test func formatSchemaJSONIsConstrainedDecodingObject() throws {
        let data = Data(NotesSchemaValidator.formatSchemaJSON.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        #expect(object["$schema"] == nil)
        #expect(object["$id"] == nil)
        let required = try #require(object["required"] as? [String])
        #expect(required.contains("title"))
        #expect(required.contains("action_items"))
        #expect(required.contains("entities"))
    }

    @Test func instantRequiresTitleAndSummary() throws {
        let notes = try validator.validate(
            """
            {"title":"Priya call","summary":"Confirmed the meeting time."}
            """,
            kind: .instant
        )
        #expect(notes.title == "Priya call")
        #expect(notes.decisions.isEmpty)
    }

    @Test func promptTemplateSubstitutesDialogue() {
        let rendered = NotesPromptTemplate.load().render(
            dialogue: "Me: hello",
            counterparty: "Priya"
        )
        #expect(rendered.contains("Me: hello"))
        #expect(rendered.contains("Priya"))
        #expect(!rendered.contains("{{DIALOGUE}}"))
    }

    static let validJSON = """
        {
          "title": "Acme - pricing follow-up",
          "summary": "Discussed volume pricing.",
          "decisions": ["Ship the pilot"],
          "action_items": [{"owner": "Ashish", "text": "Send quote", "due": "2026-09-10"}],
          "follow_ups": ["Check legal"],
          "open_questions": ["Term length?"],
          "entities": {"people": ["Priya"], "companies": ["Acme"], "amounts": [], "dates": []}
        }
        """
}

@Suite struct NotesMarkdownTests {
    @Test func rendersTitleSummaryAndActionItems() {
        let notes = CallNotes(
            title: "Acme - pricing follow-up",
            summary: "Discussed volume pricing.",
            decisions: ["Ship the pilot"],
            actionItems: [.init(owner: "Ashish", text: "Send quote", due: "2026-09-10")],
            entities: .init(people: ["Priya"], companies: ["Acme"])
        )
        let markdown = NotesMarkdown.render(notes)
        #expect(markdown.contains("# Acme - pricing follow-up"))
        #expect(markdown.contains("Discussed volume pricing."))
        #expect(markdown.contains("- Ship the pilot"))
        #expect(markdown.contains("- Ashish: Send quote (due 2026-09-10)"))
        #expect(markdown.contains("- Companies: Acme"))
        #expect(!markdown.contains("## Follow-ups"))
    }
}

@Suite struct NotesMapReduceTests {
    @Test func shortDialogueDoesNotChunk() {
        #expect(!NotesMapReduce.default.needsChunking("Me: hello\nPriya: hi"))
    }

    @Test func longDialogueSplitsOnSegmentWindows() {
        let callID = UUID()
        let segments = (0..<8).map { index in
            Segment(
                callID: callID,
                seq: index,
                startSec: TimeInterval(index),
                endSec: TimeInterval(index + 1),
                channel: index.isMultiple(of: 2) ? .near : .far,
                clusterKey: index.isMultiple(of: 2) ? "me" : "A",
                text: String(repeating: "word ", count: 80),
                provider: .appleSpeech
            )
        }
        let transcript = Transcript(
            callID: callID,
            segments: segments,
            speakerNames: ["me": "Me", "A": "Priya"]
        )
        let mapper = NotesMapReduce(transcriptTokenBudget: 50, chunkTokenBudget: 120)
        #expect(mapper.needsChunking(transcript.dialogueText()))
        let windows = mapper.windows(from: transcript)
        #expect(windows.count >= 2)
        #expect(windows.allSatisfy { $0.contains("Me:") || $0.contains("Priya:") })
    }
}

@Suite struct InstantNotesHeuristicTests {
    @Test func hangUpTitleUsesCounterparty() {
        let notes = InstantNotesHeuristic.notes(
            from: FixtureTranscript.twoSpeaker(),
            counterparty: "Priya"
        )
        #expect(notes.title == "Priya call")
        #expect(notes.summary.contains("Priya"))
    }
}
