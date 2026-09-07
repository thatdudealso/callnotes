import Foundation

/// Default deep-notes engine: Muse Glimmer 30B via local Ollama.
public struct OllamaGlimmerProvider: NotesProvider {
    public let id: NotesProviderID = .glimmer
    let engine: OllamaNotesEngine

    public var model: PinnedNotesModel { engine.model }

    public init(
        client: any OllamaServing,
        model: PinnedNotesModel = .glimmer,
        prompt: NotesPromptTemplate = .load(),
        healthProbe: (@Sendable () async -> ProviderHealth)? = nil
    ) {
        self.engine = OllamaNotesEngine(
            id: .glimmer,
            model: model,
            client: client,
            prompt: prompt,
            validator: NotesSchemaValidator(),
            mapReduce: .default,
            healthProbe: healthProbe
        )
    }

    public func generate(_ transcript: Transcript, style: NotesStyle) async throws -> CallNotes {
        try await engine.generate(transcript, style: style)
    }

    public func healthCheck() async -> ProviderHealth {
        await engine.healthCheck()
    }
}
