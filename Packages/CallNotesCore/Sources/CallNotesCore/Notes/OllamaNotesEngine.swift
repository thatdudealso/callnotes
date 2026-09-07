import Foundation

/// Shared generate + health + repair-retry used by Glimmer and the instruct fallback.
struct OllamaNotesEngine: Sendable {
    var id: NotesProviderID
    var model: PinnedNotesModel
    var client: any OllamaServing
    var prompt: NotesPromptTemplate
    var validator: NotesSchemaValidator
    var mapReduce: NotesMapReduce
    var healthProbe: (@Sendable () async -> ProviderHealth)?

    func healthCheck() async -> ProviderHealth {
        if let healthProbe {
            return await healthProbe()
        }
        do {
            let tags = try await client.listModels()
            guard let tag = tags.first(where: { OllamaClient.namesMatch($0.name, model.name) }) else {
                return .unavailable(reason: "Ollama does not have \(model.name)")
            }
            if model.matches(digest: tag.digest) {
                return .healthy
            }
            return .degraded(reason: "\(model.name) digest is \(tag.digest), expected \(model.digest)")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    func generate(_ transcript: Transcript, style: NotesStyle) async throws -> CallNotes {
        _ = style
        let dialogue = transcript.dialogueText()
        guard !dialogue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesGenerationError.emptyTranscript
        }
        if mapReduce.needsChunking(dialogue) {
            return try await generateMapped(transcript)
        }
        return try await completeValidated(
            user: prompt.render(dialogue: dialogue, counterparty: transcript.counterpartyName)
        )
    }

    private func generateMapped(_ transcript: Transcript) async throws -> CallNotes {
        let windows = mapReduce.windows(from: transcript)
        guard !windows.isEmpty else { throw NotesGenerationError.emptyTranscript }
        if windows.count == 1 {
            return try await completeValidated(
                user: prompt.render(dialogue: windows[0], counterparty: transcript.counterpartyName)
            )
        }
        var partials: [String] = []
        for (index, window) in windows.enumerated() {
            let notes = try await completeValidated(
                user: prompt.mapChunkPrompt(
                    dialogue: window,
                    index: index,
                    total: windows.count,
                    counterparty: transcript.counterpartyName
                )
            )
            partials.append(String(data: try JSONEncoder().encode(notes), encoding: .utf8) ?? "{}")
        }
        return try await completeValidated(
            user: prompt.reducePrompt(partialJSON: partials, counterparty: transcript.counterpartyName)
        )
    }

    private func completeValidated(user: String) async throws -> CallNotes {
        let system = "Return only valid call-notes JSON. Do not wrap it in markdown."
        let first = try await client.chat(
            model: model.name,
            messages: [
                OllamaChatMessage(role: "system", content: system),
                OllamaChatMessage(role: "user", content: user),
            ],
            numCtx: NotesContextBudget.numCtx
        )
        do {
            return try validator.validate(first, kind: .deep)
        } catch {
            let repaired = try await client.chat(
                model: model.name,
                messages: [
                    OllamaChatMessage(role: "system", content: system),
                    OllamaChatMessage(role: "user", content: user),
                    OllamaChatMessage(role: "assistant", content: first),
                    OllamaChatMessage(
                        role: "user",
                        content: prompt.repairPrompt(
                            invalidJSON: first,
                            error: error.localizedDescription
                        )
                    ),
                ],
                numCtx: NotesContextBudget.numCtx
            )
            return try validator.validate(repaired, kind: .deep)
        }
    }
}
