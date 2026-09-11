import Foundation
import Testing

@testable import CallNotesCore

@Suite struct CallNotesSchemaTests {
    @Test func decodesPlanSchemaJSON() throws {
        let json = """
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
        let notes = try JSONDecoder().decode(CallNotes.self, from: Data(json.utf8))
        #expect(notes.title == "Acme - pricing follow-up")
        #expect(notes.actionItems.first?.owner == "Ashish")
        #expect(notes.entities.companies == ["Acme"])
    }

    /// The phone mirrors `status` as its raw wire token and speaks the phrase
    /// for it, so every state has to have one that reads as English.
    @Test func everyCallStatusHasAHumanPhraseForItsWireToken() {
        #expect(CallStatus(rawValue: "notes_ready")?.displayName == "Notes ready")
        #expect(CallStatus.failed.displayName == "Could not finish")
        for status in CallStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(!status.displayName.contains("_"))
            #expect(status.displayName.first?.isUppercase == true)
        }
    }

    @Test func decodesInstantTitleAndSummary() throws {
        let json = """
            {"title":"Priya call","summary":"Confirmed the meeting time."}
            """
        let notes = try JSONDecoder().decode(CallNotes.self, from: Data(json.utf8))
        #expect(notes.title == "Priya call")
        #expect(notes.summary == "Confirmed the meeting time.")
        #expect(notes.actionItems.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let notes = CallNotes(
            title: "Weekly sync",
            summary: "Status review.",
            actionItems: [.init(text: "File the report")]
        )
        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode(CallNotes.self, from: data)
        #expect(decoded == notes)
    }
}
