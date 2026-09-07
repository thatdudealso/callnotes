import Foundation

/// Proven instruct-model fallback used when Glimmer is unhealthy or schema-invalid.
public struct OllamaFallbackInstruct: NotesProvider {
    public let id: NotesProviderID = .fallbackInstruct
    let engine: OllamaNotesEngine

    public var model: PinnedNotesModel { engine.model }

    public init(
        client: any OllamaServing,
        model: PinnedNotesModel = .fallbackInstruct,
        prompt: NotesPromptTemplate = .load(),
        healthProbe: (@Sendable () async -> ProviderHealth)? = nil
    ) {
        self.engine = OllamaNotesEngine(
            id: .fallbackInstruct,
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
