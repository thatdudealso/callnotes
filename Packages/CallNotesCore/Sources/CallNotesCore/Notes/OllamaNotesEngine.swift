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
        let initialTokenCount = try await exactTokenCount(messages: initialMessages(user: user))
        if initialTokenCount > min(mapReduce.transcriptTokenBudget, NotesContextBudget.maxTranscriptTokens) {
            return try await generateMapped(transcript)
        }
        return try await completeValidated(user: user)
    }

    private func generateMapped(_ transcript: Transcript) async throws -> CallNotes {
        var windows = mapReduce.windows(from: transcript)
        guard !windows.isEmpty else { throw NotesGenerationError.emptyTranscript }
        if windows.count == 1 {
            let user = prompt.render(dialogue: windows[0], counterparty: transcript.counterpartyName)
            if try await fitsInitialContext(user: user) {
                return try await completeValidated(user: user)
            }
        }
        var partials: [String] = []
        var index = 0
        while index < windows.count {
            let window = windows[index]
            let user = prompt.mapChunkPrompt(
                dialogue: window,
                index: index,
                total: windows.count,
                counterparty: transcript.counterpartyName
            )
            guard try await fitsInitialContext(user: user) else {
                let split = splitWindow(window)
                guard split.count > 1 else {
                    throw NotesGenerationError.schemaInvalid("transcript window exceeds the context budget")
                }
                windows.replaceSubrange(index...index, with: split)
                continue
            }
            let notes = try await completeValidated(
                user: user
            )
            partials.append(String(data: try JSONEncoder().encode(notes), encoding: .utf8) ?? "{}")
            index += 1
        }
        return try await reduce(partials, counterparty: transcript.counterpartyName)
    }

    private func splitWindow(_ window: String) -> [String] {
        let characters = Array(window)
        guard characters.count > 1 else { return [window] }
        let midpoint = characters.count / 2
        return [String(characters[..<midpoint]), String(characters[midpoint...])]
    }

    private func reduce(_ partials: [String], counterparty: String?) async throws -> CallNotes {
        var pending = partials
        while true {
            let groups = try await boundedReductionGroups(partialJSON: pending, counterparty: counterparty)
            if groups.count == 1 {
                return try await completeValidated(
                    user: prompt.reducePrompt(partialJSON: groups[0], counterparty: counterparty)
                )
            }
            guard groups.count < pending.count else {
                throw NotesGenerationError.schemaInvalid("reduction failed to make progress")
            }
            pending = try await groups.asyncMap { group in
                let notes = try await completeValidated(
                    user: prompt.reducePrompt(partialJSON: group, counterparty: counterparty)
                )
                return String(data: try JSONEncoder().encode(notes), encoding: .utf8) ?? "{}"
            }
        }
    }

    private func boundedReductionGroups(partialJSON: [String], counterparty: String?) async throws -> [[String]] {
        var groups: [[String]] = []
        var group: [String] = []
        for partial in partialJSON {
            let candidate = group + [partial]
            let candidatePrompt = prompt.reducePrompt(partialJSON: candidate, counterparty: counterparty)
            let candidateTokenCount = try await exactTokenCount(messages: initialMessages(user: candidatePrompt))
            if candidateTokenCount <= min(mapReduce.reducePromptTokenBudget, NotesContextBudget.maxTranscriptTokens)
            {
                group = candidate
                continue
            }
            guard !group.isEmpty else {
                throw NotesGenerationError.schemaInvalid("partial notes exceed the reduction context budget")
            }
            groups.append(group)
            let singlePrompt = prompt.reducePrompt(partialJSON: [partial], counterparty: counterparty)
            let singleTokenCount = try await exactTokenCount(messages: initialMessages(user: singlePrompt))
            guard singleTokenCount <= min(mapReduce.reducePromptTokenBudget, NotesContextBudget.maxTranscriptTokens)
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
        let firstTokenCount = try await exactTokenCount(messages: firstMessages)
        guard firstTokenCount <= NotesContextBudget.maxTranscriptTokens else {
            throw NotesGenerationError.schemaInvalid("notes prompt exceeds the context budget")
        }
        let first = try await client.chat(
            model: model.name,
            messages: firstMessages,
            numCtx: NotesContextBudget.contextWindow(forTokenCount: firstTokenCount),
            jsonSchema: schema
        )
        do {
            return try validator.validate(first, kind: .deep)
        } catch {
            let repairPrompt = prompt.repairPrompt(invalidJSON: first, error: error.localizedDescription)
            let repairMessages = [
                OllamaChatMessage(role: "user", content: repairPrompt),
            ]
            let repairTokenCount = try await exactTokenCount(messages: repairMessages)
            guard repairTokenCount <= NotesContextBudget.maxTranscriptTokens else {
                throw NotesGenerationError.schemaInvalid("invalid JSON exceeds the repair context budget")
            }
            let repaired = try await client.chat(
                model: model.name,
                messages: repairMessages,
                numCtx: NotesContextBudget.contextWindow(forTokenCount: repairTokenCount),
                jsonSchema: schema
            )
            return try validator.validate(repaired, kind: .deep)
        }
    }

    private func initialMessages(user: String) -> [OllamaChatMessage] {
        [
            OllamaChatMessage(role: "system", content: "Return only valid call-notes JSON. Do not wrap it in markdown."),
            OllamaChatMessage(role: "user", content: user),
        ]
    }

    private func fitsInitialContext(user: String) async throws -> Bool {
        try await exactTokenCount(messages: initialMessages(user: user)) <= NotesContextBudget.maxTranscriptTokens
    }

    private func exactTokenCount(messages: [OllamaChatMessage]) async throws -> Int {
        guard let tokenizer = client as? any OllamaTokenCounting else {
            throw NotesGenerationError.ollamaUnavailable("Ollama client cannot count model tokens")
        }
        return try await tokenizer.tokenCount(model: model.name, messages: messages)
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
