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
        #expect(!(await client.countedRequests()).isEmpty)
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

    @Test func mapReduceUsesBoundedHierarchicalReductions() async throws {
        let long = FixtureTranscript.longTwoSpeaker(segmentCount: 80)
        let mapper = NotesMapReduce(transcriptTokenBudget: 50, chunkTokenBudget: 80, reducePromptTokenBudget: 500)
        let windows = mapper.windows(from: long)
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: Array(repeating: Self.validJSON, count: windows.count * 2)
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: .load(), validator: NotesSchemaValidator(), mapReduce: mapper, healthProbe: nil
        )
        _ = try await engine.generate(long, style: .deep)
        let requests = await client.requests()
        let reductionRequests = requests.filter { $0.messages.last?.content.contains("Merge these partial") == true }
        #expect(reductionRequests.count > 1)
        #expect(reductionRequests.allSatisfy {
            NotesContextBudget.estimateTokens($0.messages.last?.content ?? "") <= mapper.reducePromptTokenBudget
        })
    }

    @Test func mapReduceRejectsNonProgressingReduction() async throws {
        let prompt = NotesPromptTemplate.load()
        let validator = NotesSchemaValidator()
        let partial = String(data: try JSONEncoder().encode(validator.validate(Self.validJSON, kind: .deep)), encoding: .utf8)!
        let singlePromptTokens = NotesContextBudget.estimateTokens(
            "Return only valid call-notes JSON. Do not wrap it in markdown.\n"
                + prompt.reducePrompt(partialJSON: [partial], counterparty: "Priya")
        )
        #expect(
            NotesContextBudget.estimateTokens(
                prompt.reducePrompt(partialJSON: [partial, partial], counterparty: "Priya")
            ) > singlePromptTokens
        )
        let mapper = NotesMapReduce(
            transcriptTokenBudget: 50,
            chunkTokenBudget: 80,
            reducePromptTokenBudget: singlePromptTokens
        )
        let transcript = FixtureTranscript.longTwoSpeaker(segmentCount: 8)
        let windows = mapper.windows(from: transcript)
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: Array(repeating: Self.validJSON, count: windows.count)
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: prompt, validator: validator, mapReduce: mapper, healthProbe: nil
        )
        await #expect(throws: NotesGenerationError.self) {
            try await engine.generate(transcript, style: .deep)
        }
        #expect((await client.requests()).count == windows.count)
    }

    @Test func repairRetrySizesContextFromItsCompletePayload() async throws {
        let invalid = #"{"title":"","summary":"","extra":"# + String(repeating: "word ", count: 4_000) + #""}"#
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: [invalid, Self.validJSON]
        )
        let provider = OllamaGlimmerProvider(client: client)
        _ = try await provider.generate(FixtureTranscript.twoSpeaker(), style: .deep)
        let requests = await client.requests()
        #expect(requests.count == 2)
        #expect(requests[1].messages.count == 1)
        #expect(requests[1].messages[0].role == "user")
        #expect(requests[1].messages[0].content.contains(invalid))
        #expect(requests[1].numCtx == NotesContextBudget.contextWindow(for: requests[1].messages.map(\.content).joined(separator: "\n")))
        #expect(requests[1].numCtx <= NotesContextBudget.numCtx)
    }

    @Test func oversizedSegmentUsesMultipleMapRequests() async throws {
        let callID = UUID()
        let transcript = Transcript(
            callID: callID,
            segments: [
                Segment(
                    callID: callID,
                    seq: 0,
                    startSec: 0,
                    endSec: 1,
                    channel: .near,
                    clusterKey: "me",
                    text: String(repeating: "word ", count: 500),
                    provider: .appleSpeech
                )
            ],
            speakerNames: ["me": "Me"]
        )
        let mapper = NotesMapReduce(transcriptTokenBudget: 50, chunkTokenBudget: 80)
        let windows = mapper.windows(from: transcript)
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: Array(repeating: Self.validJSON, count: windows.count + 1)
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: .load(), validator: NotesSchemaValidator(), mapReduce: mapper, healthProbe: nil
        )
        _ = try await engine.generate(transcript, style: .deep)
        let requests = await client.requests()
        #expect(requests.count == windows.count + 1)
        #expect(requests.dropLast().allSatisfy { $0.messages.last?.content.contains("This is chunk") == true })
    }

    @Test func previousUserOnlyBoundaryUsesMapRequests() async throws {
        let callID = UUID()
        let dialogueBytes = NotesContextBudget.maxTranscriptTokens * 4
        let transcript = Transcript(
            callID: callID,
            segments: [
                Segment(
                    callID: callID,
                    seq: 0,
                    startSec: 0,
                    endSec: 1,
                    channel: .near,
                    clusterKey: "me",
                    text: String(repeating: "x", count: dialogueBytes - "Me: ".utf8.count),
                    provider: .appleSpeech
                )
            ],
            speakerNames: ["me": "Me"]
        )
        #expect(NotesContextBudget.estimateTokens(transcript.dialogueText()) == NotesContextBudget.maxTranscriptTokens)
        let mapper = NotesMapReduce.default
        let windows = mapper.windows(from: transcript)
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: Array(repeating: Self.validJSON, count: windows.count + 1)
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: .load(), validator: NotesSchemaValidator(), mapReduce: mapper, healthProbe: nil
        )
        _ = try await engine.generate(transcript, style: .deep)
        let requests = await client.requests()
        #expect(requests.count == windows.count + 1)
        #expect(requests.dropLast().allSatisfy { $0.messages.last?.content.contains("This is chunk") == true })
    }

    @Test func tokenizerKeepsCompressiblePromptOneShot() async throws {
        let callID = UUID()
        let transcript = Transcript(
            callID: callID,
            segments: [
                Segment(
                    callID: callID,
                    seq: 0,
                    startSec: 0,
                    endSec: 1,
                    channel: .near,
                    clusterKey: "me",
                    text: String(repeating: "!", count: (NotesContextBudget.maxTranscriptTokens + 1) * 4),
                    provider: .appleSpeech
                )
            ],
            speakerNames: ["me": "Me"]
        )
        #expect(NotesContextBudget.estimateTokens(transcript.dialogueText()) > NotesContextBudget.maxTranscriptTokens)
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: [Self.validJSON],
            tokenCountOverride: 100
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: .load(), validator: NotesSchemaValidator(), mapReduce: .default, healthProbe: nil
        )
        _ = try await engine.generate(transcript, style: .deep)
        #expect((await client.requests()).count == 1)
    }

    @Test func tokenizerCountOverGenerationContextUsesMapRequests() async throws {
        let callID = UUID()
        let transcript = Transcript(
            callID: callID,
            segments: [
                Segment(
                    callID: callID,
                    seq: 0,
                    startSec: 0,
                    endSec: 1,
                    channel: .near,
                    clusterKey: "me",
                    text: String(repeating: "word ", count: 35_000),
                    provider: .appleSpeech
                )
            ],
            speakerNames: ["me": "Me"]
        )
        let client = ScriptedOllamaClient(
            tags: [OllamaModelTag(name: PinnedNotesModel.glimmer.name, digest: PinnedNotesModel.glimmer.digest)],
            replies: Array(repeating: Self.validJSON, count: 20),
            tokenCounts: [40_000] + Array(repeating: 100, count: 100)
        )
        let engine = OllamaNotesEngine(
            id: .glimmer, model: .glimmer, client: client, prompt: .load(), validator: NotesSchemaValidator(), mapReduce: .default, healthProbe: nil
        )
        _ = try await engine.generate(transcript, style: .deep)
        #expect((await client.requests()).count > 1)
    }

    @Test func openaiChatResponseDecodesContent() throws {
        let data = Data(
            """
            {"choices":[{"message":{"content":"{\\"title\\":\\"x\\"}"}}]}
            """.utf8
        )
        #expect(try OllamaClient.decodeChatContent(data) == "{\"title\":\"x\"}")
    }

    @Test func nativeChatResponseDecodesContent() throws {
        let data = Data(
            """
            {"message":{"role":"assistant","content":"{\\"title\\":\\"y\\"}"}}
            """.utf8
        )
        #expect(try OllamaClient.decodeChatContent(data) == "{\"title\":\"y\"}")
    }

    @Test func nativeTokenizeResponseDecodesExactCount() throws {
        let data = Data("{\"tokens\":[1,2,3,4]}".utf8)
        #expect(try OllamaClient.decodeTokenCount(data) == 4)
    }

    @Test func tokenCountUsesNativeTokenizerRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenizeOnlyURLProtocol.self]
        let client = OllamaClient(
            baseURL: URL(string: "http://tokenizer.test")!,
            session: URLSession(configuration: configuration)
        )

        let count = try await client.tokenCount(
            model: PinnedNotesModel.glimmer.name,
            messages: [
                OllamaChatMessage(role: "system", content: "System instructions"),
                OllamaChatMessage(role: "user", content: "Transcript content"),
            ]
        )

        #expect(count == 4)
    }

    @Test func nativeChatResponseStripsTrailingStopToken() throws {
        let data = Data(
            """
            {"message":{"role":"assistant","content":"{\\"title\\":\\"y\\"}<|eot|>"}}
            """.utf8
        )
        #expect(try OllamaClient.decodeChatContent(data) == "{\"title\":\"y\"}")
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
    @Test func bootstrapModelCatalogMatchesRuntimePins() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let root = (0..<5).reduce(sourceFile) { url, _ in url.deletingLastPathComponent() }
        let document = try String(contentsOf: root.appending(path: "docs/models.md"), encoding: .utf8)
        let catalog = Dictionary(uniqueKeysWithValues: document
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 4,
                    fields[2].hasPrefix("`"), fields[3].hasPrefix("`sha256:")
                else {
                    return nil
                }
                return (
                    String(fields[2].dropFirst().dropLast()),
                    String(fields[3].dropFirst().dropLast())
                )
            })
        #expect(catalog == Dictionary(uniqueKeysWithValues: PinnedNotesModel.all.map { ($0.name, $0.digest) }))
    }

    @Test func acceptsCompletePinnedDigests() {
        #expect(PinnedNotesModel.glimmer.matches(digest: PinnedNotesModel.glimmer.digest))
        #expect(PinnedNotesModel.fallbackInstruct.matches(digest: PinnedNotesModel.fallbackInstruct.digest))
    }

    @Test func rejectsIncompleteModelDigests() {
        let model = PinnedNotesModel.glimmer
        #expect(model.matches(digest: model.digest.replacingOccurrences(of: "sha256:", with: "")))
        #expect(!model.matches(digest: ""))
        #expect(!model.matches(digest: String(model.digest.suffix(16))))
    }

    @Test func contextWindowScalesWithPromptSize() {
        #expect(NotesContextBudget.contextWindow(for: "short") == 8_192)
        let medium = String(repeating: "word ", count: 4_000)
        #expect(NotesContextBudget.contextWindow(for: medium) == 16_384)
        let long = String(repeating: "word ", count: 12_000)
        #expect(NotesContextBudget.contextWindow(for: long) == 32_768)
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

    static func longTwoSpeaker(callID: UUID = UUID(), segmentCount: Int = 24) -> Transcript {
        let segments = (0..<segmentCount).map { index in
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

private final class TokenizeOnlyURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "tokenizer.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let validRequest: Bool
        if let body = Self.requestBody(request),
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let messages = payload["messages"] as? [[String: String]],
            request.url?.path == "/api/tokenize",
            payload["model"] as? String == PinnedNotesModel.glimmer.name,
            payload["add_generation_prompt"] as? Bool == true,
            messages == [
                ["role": "system", "content": "System instructions"],
                ["role": "user", "content": "Transcript content"],
            ]
        {
            validRequest = true
        } else {
            validRequest = false
        }

        let status = validRequest ? 200 : 400
        let body = Data(validRequest ? "{\"tokens\":[1,2,3,4]}".utf8 : "invalid tokenizer request".utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

actor ScriptedOllamaClient: OllamaServing, OllamaTokenCounting {
    struct Request: Sendable {
        var messages: [OllamaChatMessage]
        var numCtx: Int
    }

    var tags: [OllamaModelTag]
    var replies: [String]
    var recordedRequests: [Request] = []
    var tokenCountRequests: [[OllamaChatMessage]] = []
    var tokenCountOverride: Int?
    var tokenCounts: [Int]

    init(
        tags: [OllamaModelTag],
        replies: [String],
        tokenCountOverride: Int? = nil,
        tokenCounts: [Int] = []
    ) {
        self.tags = tags
        self.replies = replies
        self.tokenCountOverride = tokenCountOverride
        self.tokenCounts = tokenCounts
    }

    func chat(model: String, messages: [OllamaChatMessage], numCtx: Int, jsonSchema: String?) async throws -> String {
        _ = model
        _ = jsonSchema
        recordedRequests.append(Request(messages: messages, numCtx: numCtx))
        guard !replies.isEmpty else {
            throw NotesGenerationError.ollamaUnavailable("scripted Ollama has no replies")
        }
        return replies.removeFirst()
    }

    func listModels() async throws -> [OllamaModelTag] {
        tags
    }

    func tokenCount(model: String, messages: [OllamaChatMessage]) async throws -> Int {
        _ = model
        tokenCountRequests.append(messages)
        if !tokenCounts.isEmpty {
            return tokenCounts.removeFirst()
        }
        return tokenCountOverride ?? NotesContextBudget.estimateTokens(messages.map(\.content).joined(separator: "\n"))
    }

    func requests() -> [Request] {
        recordedRequests
    }

    func countedRequests() -> [[OllamaChatMessage]] {
        tokenCountRequests
    }
}
