import Foundation
import Testing

@testable import CallNotesCore

@Suite struct NotesOllamaHarnessTests {
    @Test func liveDeepNotesValidateForBothModelsAndMeetSpeedTarget() async throws {
        guard ProcessInfo.processInfo.environment["CALLNOTES_OLLAMA"] == "1" else {
            return
        }
        guard let client = await OllamaClient.makeIfReady() else {
            Issue.record("CALLNOTES_OLLAMA=1 but Ollama is not reachable at 127.0.0.1:11434")
            return
        }
        let transcript = FixtureTranscript.twoSpeaker()
        let glimmer = OllamaGlimmerProvider(client: client)
        let fallback = OllamaFallbackInstruct(client: client)
        let glimmerHealth = await glimmer.healthCheck()
        let fallbackHealth = await fallback.healthCheck()
        #expect(glimmerHealth.isUsable)
        #expect(fallbackHealth.isUsable)

        let glimmerStarted = ContinuousClock.now
        let glimmerNotes = try await glimmer.generate(transcript, style: .deep)
        let glimmerElapsed = ContinuousClock.now - glimmerStarted
        #expect(!glimmerNotes.title.isEmpty)
        #expect(!glimmerNotes.summary.isEmpty)
        #expect(glimmerElapsed < NotesContextBudget.speedTarget)
        FileHandle.standardError.write(
            Data("callnotes notes speed glimmer=\(glimmerElapsed) target=60s\n".utf8)
        )

        let fallbackStarted = ContinuousClock.now
        let fallbackNotes = try await fallback.generate(transcript, style: .deep)
        let fallbackElapsed = ContinuousClock.now - fallbackStarted
        #expect(!fallbackNotes.title.isEmpty)
        #expect(!fallbackNotes.summary.isEmpty)
        #expect(fallbackElapsed < NotesContextBudget.speedTarget)
        FileHandle.standardError.write(
            Data("callnotes notes speed fallback=\(fallbackElapsed) target=60s\n".utf8)
        )
    }
}
