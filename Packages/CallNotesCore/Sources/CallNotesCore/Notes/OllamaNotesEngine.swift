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
        let user = prompt.render(dialogue: dialogue, counterparty: transcript.counterpartyName)
        if mapReduce.needsChunking(dialogue) || !fitsInitialContext(user: user) {
            return try await generateMapped(transcript)
        }
        return try await completeValidated(user: user)
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
        return try await reduce(partials, counterparty: transcript.counterpartyName)
    }

    private func reduce(_ partials: [String], counterparty: String?) async throws -> CallNotes {
        var pending = partials
        while true {
            let groups = try boundedReductionGroups(partialJSON: pending, counterparty: counterparty)
            if groups.count == 1 {
                return try await completeValidated(
                    user: prompt.reducePrompt(partialJSON: groups[0], counterparty: counterparty)
                )
            }
            pending = try await groups.asyncMap { group in
                let notes = try await completeValidated(
                    user: prompt.reducePrompt(partialJSON: group, counterparty: counterparty)
                )
                return String(data: try JSONEncoder().encode(notes), encoding: .utf8) ?? "{}"
            }
        }
    }

    private func boundedReductionGroups(partialJSON: [String], counterparty: String?) throws -> [[String]] {
        var groups: [[String]] = []
        var group: [String] = []
        for partial in partialJSON {
            let candidate = group + [partial]
            let candidatePrompt = prompt.reducePrompt(partialJSON: candidate, counterparty: counterparty)
            if NotesContextBudget.estimateTokens(candidatePrompt) <= mapReduce.reducePromptTokenBudget,
                fitsInitialContext(user: candidatePrompt)
            {
                group = candidate
                continue
            }
            guard !group.isEmpty else {
                throw NotesGenerationError.schemaInvalid("partial notes exceed the reduction context budget")
            }
            groups.append(group)
            let singlePrompt = prompt.reducePrompt(partialJSON: [partial], counterparty: counterparty)
            guard NotesContextBudget.estimateTokens(singlePrompt) <= mapReduce.reducePromptTokenBudget,
                fitsInitialContext(user: singlePrompt)
            else {
                throw NotesGenerationError.schemaInvalid("partial notes exceed the reduction context budget")
            }
            group = [partial]
        }
        if !group.isEmpty {
            groups.append(group)
        }
        return groups
    }

    private func completeValidated(user: String) async throws -> CallNotes {
        let schema = NotesSchemaValidator.formatSchemaJSON
        let firstMessages = initialMessages(user: user)
        guard fitsInitialContext(user: user) else {
            throw NotesGenerationError.schemaInvalid("notes prompt exceeds the context budget")
        }
        let first = try await client.chat(
            model: model.name,
            messages: firstMessages,
            numCtx: contextWindow(for: firstMessages),
            jsonSchema: schema
        )
        do {
            return try validator.validate(first, kind: .deep)
        } catch {
            let repairPrompt = prompt.repairPrompt(invalidJSON: first, error: error.localizedDescription)
            let repairMessages = [
                OllamaChatMessage(role: "user", content: repairPrompt),
            ]
            guard NotesContextBudget.estimateTokens(repairPrompt) <= NotesContextBudget.maxTranscriptTokens else {
                throw NotesGenerationError.schemaInvalid("invalid JSON exceeds the repair context budget")
            }
            let repaired = try await client.chat(
                model: model.name,
                messages: repairMessages,
                numCtx: contextWindow(for: repairMessages),
                jsonSchema: schema
            )
            return try validator.validate(repaired, kind: .deep)
        }
    }

    private func contextWindow(for messages: [OllamaChatMessage]) -> Int {
        NotesContextBudget.contextWindow(for: messages.map(\.content).joined(separator: "\n"))
    }

    private func initialMessages(user: String) -> [OllamaChatMessage] {
        [
            OllamaChatMessage(role: "system", content: "Return only valid call-notes JSON. Do not wrap it in markdown."),
            OllamaChatMessage(role: "user", content: user),
        ]
    }

    private func fitsInitialContext(user: String) -> Bool {
        NotesContextBudget.estimateTokens(initialMessages(user: user).map(\.content).joined(separator: "\n"))
            <= NotesContextBudget.maxTranscriptTokens
    }
}

private extension Array {
    func asyncMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async throws -> T) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
