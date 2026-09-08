import Foundation

/// Instant title/tldr at hang-up, then deep notes with Glimmer and automatic instruct fallback.
public struct NotesGenerationSpine: Sendable {
    public var instant: any NotesProvider
    public var deep: any NotesProvider
    public var fallback: any NotesProvider
    public var store: any CallStore

    public init(
        instant: any NotesProvider,
        deep: any NotesProvider,
        fallback: any NotesProvider,
        store: any CallStore
    ) {
        self.instant = instant
        self.deep = deep
        self.fallback = fallback
        self.store = store
    }

    @available(macOS 26, iOS 26, *)
    public init(client: any OllamaServing, store: any CallStore) {
        self.init(
            instant: AppleFMProvider(),
            deep: OllamaGlimmerProvider(client: client),
            fallback: OllamaFallbackInstruct(client: client),
            store: store
        )
    }

    /// Hang-up path: Apple FM title + tl;dr, with a heuristic fallback so the list is never blank.
    public func generateInstant(_ transcript: Transcript, call: Call) async throws -> NotesRecord {
        let notes: CallNotes
        let provider: NotesProviderID
        if await instant.healthCheck().isUsable, let generated = try? await instant.generate(transcript, style: .instant),
            !generated.title.isEmpty, !generated.summary.isEmpty
        {
            notes = generated
            provider = instant.id
        } else {
            notes = InstantNotesHeuristic.notes(from: transcript, counterparty: call.counterpartyName)
            provider = .appleFM
        }
        let record = NotesRecord(
            callID: call.id,
            provider: provider,
            promptVersion: NotesPromptTemplate.version,
            body: notes
        )
        try await store.upsertNotes(record)
        return record
    }

    /// Background deep notes. Schema-invalid Glimmer output after repair uses the instruct fallback.
    public func generateDeep(_ transcript: Transcript, call: Call) async throws -> NotesRecord {
        let (notes, provider, digest) = try await generateDeepBody(transcript)
        let record = NotesRecord(
            callID: call.id,
            provider: provider.id,
            modelDigest: digest,
            promptVersion: NotesPromptTemplate.version,
            body: notes
        )
        try await store.upsertNotes(record)
        var working = call
        working.notesProvider = provider.id
        working.status = .notesReady
        working.error = nil
        working.errorStage = nil
        try await store.upsertCall(working)
        return record
    }

    public func regenerate(_ transcript: Transcript, call: Call) async throws -> NotesRecord {
        try await generateDeep(transcript, call: call)
    }

    private func generateDeepBody(_ transcript: Transcript) async throws -> (
        CallNotes, any NotesProvider, String?
    ) {
        if await deep.healthCheck().isUsable, let notes = try? await deep.generate(transcript, style: .deep) {
            return (notes, deep, digest(for: deep))
        }
        guard await fallback.healthCheck().isUsable else {
            throw NotesGenerationError.ollamaUnavailable("deep notes and fallback are both unusable")
        }
        let notes = try await fallback.generate(transcript, style: .deep)
        return (notes, fallback, digest(for: fallback))
    }

    private func digest(for provider: any NotesProvider) -> String? {
        switch provider.id {
        case .glimmer:
            return PinnedNotesModel.glimmer.digest
        case .fallbackInstruct:
            return PinnedNotesModel.fallbackInstruct.digest
        case .appleFM:
            return nil
        }
    }
}
