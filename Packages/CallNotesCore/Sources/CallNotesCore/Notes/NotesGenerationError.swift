import Foundation

/// Failures from notes generation, schema validation, or Ollama.
public enum NotesGenerationError: Error, LocalizedError, Sendable, Equatable {
    case emptyTranscript
    case schemaInvalid(String)
    case ollamaUnavailable(String)
    case foundationModelsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "The transcript is empty, so notes cannot be generated."
        case let .schemaInvalid(reason):
            "Notes JSON did not match the schema: \(reason)"
        case let .ollamaUnavailable(reason):
            "Ollama is unavailable: \(reason)"
        case let .foundationModelsUnavailable(reason):
            "Apple Foundation Models are unavailable: \(reason)"
        }
    }
}
