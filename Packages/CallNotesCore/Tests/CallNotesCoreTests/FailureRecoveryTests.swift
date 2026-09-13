import Foundation
import Testing

@testable import CallNotesCore

@Suite struct FailureRecoveryTests {
    @Test func transcriptionFailureOffersRetranscribe() {
        let presentation = FailurePresentation.make(
            error: "SpeechAnalyzer timed out",
            errorStage: "transcription",
            hasAudio: true
        )
        #expect(presentation.headline == "Transcription failed")
        #expect(presentation.action == .retranscribe)
        #expect(presentation.actionTitle == "Retry transcription")
        #expect(presentation.detail.contains("SpeechAnalyzer timed out"))
    }

    @Test func notesFailureOffersRegenerate() {
        let presentation = FailurePresentation.make(
            error: "Ollama is not running",
            errorStage: "notes",
            hasAudio: true
        )
        #expect(presentation.action == .regenerateNotes)
        #expect(presentation.actionTitle == "Retry notes")
    }

    @Test func persistenceFailureOffersPersistenceRetry() {
        let presentation = FailurePresentation.make(
            error: "Database unavailable",
            errorStage: "persistence",
            hasAudio: true
        )
        #expect(presentation.action == .retryPersistence)
        #expect(presentation.actionTitle == "Retry saving")
    }

    @Test func captureFailureWithoutAudioHasNoRetry() {
        let presentation = FailurePresentation.make(
            error: "Microphone was denied",
            errorStage: "capture",
            hasAudio: false
        )
        #expect(presentation.action == .none)
        #expect(presentation.actionTitle == nil)
        #expect(presentation.detail.contains("No recording file was found"))
    }

    @Test func captureFailureWithPartialAudioOffersRecover() {
        let presentation = FailurePresentation.make(
            error: "Recording did not finish.",
            errorStage: "capture",
            hasAudio: true
        )
        #expect(presentation.action == .recoverPartial)
    }
}
