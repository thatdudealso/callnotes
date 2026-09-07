import Foundation
import Testing

@testable import CallNotesCore

@Suite struct NotesGenerationSpineTests {
    @Test func hangUpPersistsInstantTitleWhenFoundationModelsUnavailable() async throws {
        let store = MemoryStore()
        let call = try await Self.insertCall(store)
        let spine = NotesGenerationSpine(
            instant: ScriptedNotesProvider(
                id: .appleFM,
                health: .unavailable(reason: "test"),
                outputs: []
            ),
            deep: ScriptedNotesProvider(id: .glimmer, outputs: []),
            fallback: ScriptedNotesProvider(id: .fallbackInstruct, outputs: []),
            store: store
        )

        let record = try await spine.generateInstant(FixtureTranscript.twoSpeaker(callID: call.id), call: call)

        #expect(record.provider == .appleFM)
        #expect(record.body.title == "Priya call")
        #expect(try await store.fetchPreferredNotes(callID: call.id)?.body.title == "Priya call")
    }

    @Test func forcingGlimmerFailureProducesValidFallbackNotes() async throws {
        let store = MemoryStore()
        let call = try await Self.insertCall(store)
        let fallbackNotes = Self.fixtureNotes
        let spine = NotesGenerationSpine(
            instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
            deep: ScriptedNotesProvider(
                id: .glimmer,
                health: .healthy,
                outputs: [.failure(NotesGenerationError.schemaInvalid("forced"))]
            ),
            fallback: ScriptedNotesProvider(id: .fallbackInstruct, outputs: [.success(fallbackNotes)]),
            store: store
        )

        let record = try await spine.generateDeep(FixtureTranscript.twoSpeaker(callID: call.id), call: call)

        #expect(record.provider == .fallbackInstruct)
        #expect(record.body == fallbackNotes)
        #expect(record.modelDigest == PinnedNotesModel.fallbackInstruct.digest)
        #expect(try await store.fetchCall(id: call.id)?.status == .notesReady)
        #expect(try await store.fetchCall(id: call.id)?.notesProvider == .fallbackInstruct)
        #expect(try await store.fetchPreferredNotes(callID: call.id)?.provider == .fallbackInstruct)
    }

    @Test func unavailableGlimmerSkipsStraightToFallback() async throws {
        let store = MemoryStore()
        let call = try await Self.insertCall(store)
        let spine = NotesGenerationSpine(
            instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
            deep: ScriptedNotesProvider(
                id: .glimmer,
                health: .unavailable(reason: "not pulled"),
                outputs: [.success(Self.fixtureNotes)]
            ),
            fallback: ScriptedNotesProvider(id: .fallbackInstruct, outputs: [.success(Self.fixtureNotes)]),
            store: store
        )

        let record = try await spine.generateDeep(FixtureTranscript.twoSpeaker(callID: call.id), call: call)
        #expect(record.provider == .fallbackInstruct)
    }

    @Test func regenerateInsertsANewDeepNotesRow() async throws {
        let store = MemoryStore()
        let call = try await Self.insertCall(store)
        let first = CallNotes(title: "First", summary: "First summary.", decisions: ["One"])
        let second = CallNotes(title: "Second", summary: "Second summary.", decisions: ["Two"])
        let spine = NotesGenerationSpine(
            instant: ScriptedNotesProvider(id: .appleFM, health: .unavailable(reason: "test"), outputs: []),
            deep: ScriptedNotesProvider(
                id: .glimmer,
                outputs: [.success(first), .success(second)]
            ),
            fallback: ScriptedNotesProvider(id: .fallbackInstruct, outputs: []),
            store: store
        )
        let transcript = FixtureTranscript.twoSpeaker(callID: call.id)
        _ = try await spine.generateDeep(transcript, call: call)
        let regenerated = try await spine.regenerate(transcript, call: call)

        #expect(regenerated.body.title == "Second")
        #expect(try await store.fetchNotes(callID: call.id).count == 2)
        #expect(try await store.fetchPreferredNotes(callID: call.id)?.body.title == "Second")
    }

    @Test func preferredNotesPreferDeepOverInstant() {
        let callID = UUID()
        let instant = NotesRecord(
            callID: callID,
            provider: .appleFM,
            body: CallNotes(title: "Instant", summary: "tldr"),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let deep = NotesRecord(
            callID: callID,
            provider: .glimmer,
            body: Self.fixtureNotes,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(NotesRecord.preferred(in: [instant, deep])?.provider == .glimmer)
    }

    private static let fixtureNotes = CallNotes(
        title: "Priya - meeting time and pilot",
        summary: "Confirmed the meeting time and agreed to ship the pilot next week.",
        decisions: ["Ship the pilot next week"],
        entities: .init(people: ["Priya"], dates: ["next week"])
    )

    private static func insertCall(_ store: MemoryStore) async throws -> Call {
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            counterpartyName: "Priya",
            audioPath: "/tmp/two-speaker.caf",
            sttProvider: .appleSpeech,
            status: .transcribed
        )
        try await store.upsertCall(call)
        return call
    }
}

@Suite struct OllamaNotesProviderTests {
    @Test func glimmerRepairRetryThenValidates() async throws {
        let client = ScriptedOllamaClient(
            tags: [
                OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)
            ],
            replies: [Self.invalidJSON, Self.validJSON]
        )
        let provider = OllamaGlimmerProvider(client: client)
        let notes = try await provider.generate(FixtureTranscript.twoSpeaker(), style: .deep)
        #expect(notes.title == "Priya - meeting time and pilot")
        #expect(await provider.healthCheck() == .healthy)
    }

    @Test func glimmerThrowsAfterFailedRepair() async throws {
        let client = ScriptedOllamaClient(
            tags: [
                OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)
            ],
            replies: [Self.invalidJSON, Self.invalidJSON]
        )
        let provider = OllamaGlimmerProvider(client: client)
        await #expect(throws: NotesGenerationError.self) {
            try await provider.generate(FixtureTranscript.twoSpeaker(), style: .deep)
        }
    }

    @Test func fallbackHealthChecksPinnedDigest() async {
        let client = ScriptedOllamaClient(
            tags: [
                OllamaModelTag(
                    name: PinnedNotesModel.fallbackInstruct.name,
                    digest: PinnedNotesModel.fallbackInstruct.digest
                )
            ],
            replies: []
        )
        let provider = OllamaFallbackInstruct(client: client)
        #expect(await provider.healthCheck() == .healthy)
    }

    @Test func mapReduceCompletesEachWindowThenReduces() async throws {
        let long = FixtureTranscript.longTwoSpeaker()
        let mapper = NotesMapReduce(transcriptTokenBudget: 50, chunkTokenBudget: 80)
        #expect(mapper.needsChunking(long.dialogueText()))
        let windows = mapper.windows(from: long)
        #expect(windows.count >= 2)

        var replies = Array(repeating: Self.validJSON, count: windows.count + 1)
        replies[replies.count - 1] = Self.reducedJSON
        let client = ScriptedOllamaClient(
            tags: [
                OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)
            ],
            replies: replies
        )
        let engine = OllamaNotesEngine(
            id: .glimmer,
            model: .glimmer,
            client: client,
            prompt: .load(),
            validator: NotesSchemaValidator(),
            mapReduce: mapper,
            healthProbe: nil
        )
        let notes = try await engine.generate(long, style: .deep)
        #expect(notes.title == "Priya - long call")
    }

    @Test func openaiChatResponseDecodesContent() throws {
        let data = Data(
            """
            {"choices":[{"message":{"content":"{\\"title\\":\\"x\\"}"}}]}
            """.utf8
        )
        #expect(try OllamaClient.decodeChatContent(data) == "{\"title\":\"x\"}")
    }

    static let invalidJSON = #"{"title":"","summary":""}"#
    static let validJSON = """
        {
          "title": "Priya - meeting time and pilot",
          "summary": "Confirmed the meeting time and agreed to ship the pilot next week.",
          "decisions": ["Ship the pilot next week"],
          "action_items": [],
          "follow_ups": [],
          "open_questions": [],
          "entities": {"people": ["Priya"], "companies": [], "amounts": [], "dates": ["next week"]}
        }
        """
    static let reducedJSON = """
        {
          "title": "Priya - long call",
          "summary": "Merged notes from every window.",
          "decisions": ["Ship the pilot next week"],
          "action_items": [],
          "follow_ups": [],
          "open_questions": [],
          "entities": {"people": ["Priya"], "companies": [], "amounts": [], "dates": []}
        }
        """
}

@Suite struct NotesStoreTests {
    @Test func memoryStoreRoundTripsNotes() async throws {
        let store = MemoryStore()
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: "/tmp/n.caf",
            sttProvider: .appleSpeech,
            status: .transcribed
        )
        try await store.upsertCall(call)
        let record = NotesRecord(
            callID: call.id,
            provider: .glimmer,
            modelDigest: PinnedNotesModel.glimmer.digest,
            body: CallNotes(title: "Priya call", summary: "Ship the pilot.")
        )
        try await store.upsertNotes(record)
        #expect(try await store.fetchNotes(callID: call.id).first?.body.title == "Priya call")
        #expect(try await store.fetchPreferredNotes(callID: call.id)?.modelDigest == PinnedNotesModel.glimmer.digest)
    }

    @Test func livePostgresPersistsNotesWhenReachable() async throws {
        guard let store = await PostgresStore.makeIfAvailable() else {
            return
        }
        try await store.migrate()
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            counterpartyName: "Priya",
            audioPath: "/tmp/phase3-notes.caf",
            sttProvider: .appleSpeech,
            status: .transcribed
        )
        try await store.upsertCall(call)
        let record = NotesRecord(
            callID: call.id,
            provider: .fallbackInstruct,
            modelDigest: PinnedNotesModel.fallbackInstruct.digest,
            body: CallNotes(
                title: "Priya - meeting time and pilot",
                summary: "Confirmed the meeting time and agreed to ship the pilot next week.",
                decisions: ["Ship the pilot next week"]
            )
        )
        try await store.upsertNotes(record)
        let fetched = try await store.fetchPreferredNotes(callID: call.id)
        #expect(fetched?.body.title == "Priya - meeting time and pilot")
        #expect(fetched?.provider == .fallbackInstruct)
    }
}

@Suite struct PinnedNotesModelTests {
    @Test func matchesDocsModelsDigests() {
        #expect(PinnedNotesModel.glimmer.name == "muse-glimmer:30b")
        #expect(
            PinnedNotesModel.glimmer.digest
                == "sha256:de878ce33ad81d060001db1469a02eebe4d86f0ad58cfe52dc062fdcbe4464c1"
        )
        #expect(PinnedNotesModel.fallbackInstruct.name == "qwen3:30b-instruct")
        #expect(
            PinnedNotesModel.fallbackInstruct.digest
                == "sha256:19e422b0231392335cfc49cfd172de7034bb1aeabb08aa307cce745c60b272fe"
        )
        #expect(PinnedNotesModel.glimmer.matches(digest: PinnedNotesModel.glimmer.digest))
    }
}

enum FixtureTranscript {
    static func twoSpeaker(callID: UUID = UUID()) -> Transcript {
        Transcript(
            callID: callID,
            segments: [
                Segment(
                    callID: callID,
                    seq: 0,
                    startSec: 0,
                    endSec: 3,
                    channel: .near,
                    clusterKey: "me",
                    text: "Hello Priya, this is the near channel confirming the meeting time.",
                    provider: .appleSpeech
                ),
                Segment(
                    callID: callID,
                    seq: 1,
                    startSec: 2.4,
                    endSec: 5,
                    channel: .far,
                    clusterKey: "A",
                    text: "Hi, this is Priya on the far channel. Let's ship the pilot next week.",
                    provider: .appleSpeech
                ),
            ],
            speakerNames: ["me": "Me", "A": "Priya"],
            counterpartyName: "Priya"
        )
    }

    static func longTwoSpeaker(callID: UUID = UUID()) -> Transcript {
        let segments = (0..<24).map { index in
            Segment(
                callID: callID,
                seq: index,
                startSec: TimeInterval(index),
                endSec: TimeInterval(index + 1),
                channel: index.isMultiple(of: 2) ? .near : .far,
                clusterKey: index.isMultiple(of: 2) ? "me" : "A",
                text: "Turn \(index) discussing the pilot, legal review, and next week's ship date.",
                provider: .appleSpeech
            )
        }
        return Transcript(
            callID: callID,
            segments: segments,
            speakerNames: ["me": "Me", "A": "Priya"],
            counterpartyName: "Priya"
        )
    }
}

final class ScriptedNotesProvider: NotesProvider, @unchecked Sendable {
    let id: NotesProviderID
    var health: ProviderHealth
    var outputs: [Result<CallNotes, Error>]

    init(id: NotesProviderID, health: ProviderHealth = .healthy, outputs: [Result<CallNotes, Error>]) {
        self.id = id
        self.health = health
        self.outputs = outputs
    }

    func generate(_ transcript: Transcript, style: NotesStyle) async throws -> CallNotes {
        _ = transcript
        _ = style
        guard !outputs.isEmpty else {
            throw NotesGenerationError.schemaInvalid("scripted provider has no outputs")
        }
        switch outputs.removeFirst() {
        case let .success(notes):
            return notes
        case let .failure(error):
            throw error
        }
    }

    func healthCheck() async -> ProviderHealth {
        health
    }
}

actor ScriptedOllamaClient: OllamaServing {
    var tags: [OllamaModelTag]
    var replies: [String]

    init(tags: [OllamaModelTag], replies: [String]) {
        self.tags = tags
        self.replies = replies
    }

    func chat(model: String, messages: [OllamaChatMessage], numCtx: Int) async throws -> String {
        _ = model
        _ = messages
        _ = numCtx
        guard !replies.isEmpty else {
            throw NotesGenerationError.ollamaUnavailable("scripted Ollama has no replies")
        }
        return replies.removeFirst()
    }

    func listModels() async throws -> [OllamaModelTag] {
        tags
    }
}
