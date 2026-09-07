import Foundation
import Testing

@testable import CallNotesCore

@Suite struct MemoryStoreTests {
    @Test func roundTripsCallSegmentsAndSpeaker() async throws {
        let store = MemoryStore()
        try await store.migrate()
        let call = Call(
            source: .fileImport,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: "/tmp/sample.caf",
            sttProvider: .appleSpeech,
            status: .transcribed
        )
        try await store.upsertCall(call)

        let owner = SpeakerIdentity.enroll(
            displayName: "Me",
            isOwner: true,
            embedding: VectorCodec.pad([1, 0, 0]),
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertSpeakerProfile(owner)

        let segment = Segment(
            callID: call.id,
            seq: 0,
            startSec: 0,
            endSec: 1,
            channel: .near,
            clusterKey: "me",
            text: "hello",
            provider: .appleSpeech
        )
        try await store.replaceSegments(callID: call.id, provider: .appleSpeech, [segment])
        try await store.replaceCallSpeakers(
            callID: call.id,
            speakers: [CallSpeaker(callID: call.id, clusterKey: "me", profileID: owner.id, confidence: 1)]
        )

        let fetched = try await store.fetchCall(id: call.id)
        #expect(fetched?.id == call.id)
        #expect(try await store.fetchSegments(callID: call.id, provider: .appleSpeech).map(\.text) == ["hello"])
        #expect(try await store.fetchSpeakerProfiles().contains { $0.id == owner.id })
        #expect(try await store.fetchCallSpeakers(callID: call.id).first?.profileID == owner.id)
    }

    @Test func emptySpeakerReplacementClearsExistingMappings() async throws {
        let store = MemoryStore()
        let callID = UUID()
        try await store.replaceCallSpeakers(
            callID: callID,
            speakers: [CallSpeaker(callID: callID, clusterKey: "A", labelOverride: "Speaker 2")]
        )

        try await store.replaceCallSpeakers(callID: callID, speakers: [])

        #expect(try await store.fetchCallSpeakers(callID: callID).isEmpty)
    }
}

@Suite struct ChannelAudioTests {
    @Test func roundTripsStereoCAFChannels() throws {
        let sampleRate = 16_000.0
        var near = [Int16](repeating: 0, count: 1600)
        var far = [Int16](repeating: 0, count: 1600)
        for index in 0..<1600 {
            near[index] = Int16(index)
            far[index] = Int16(-index)
        }
        let nearData = near.withUnsafeBytes { Data($0) }
        let farData = far.withUnsafeBytes { Data($0) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-channel-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(near: nearData, far: farData, sampleRate: sampleRate, to: url)
        let split = try ChannelAudio.splitStereoCAF(url: url)
        #expect(split.frameCount == 1600)
        let nearOut = split.near.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let farOut = split.far.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(nearOut.first == 0)
        #expect(nearOut[10] == 10)
        #expect(farOut[10] == -10)
    }
}

@Suite struct SpineTests {
    @Test func fixtureCAFFlowsToStoreWithAttributedSpeakers() async throws {
        let store = MemoryStore()
        try await store.migrate()
        let owner = SpeakerIdentity.enroll(
            displayName: "Me",
            isOwner: true,
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        let priya = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [0, 1, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertSpeakerProfile(owner)
        try await store.upsertSpeakerProfile(priya)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-spine-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 3200),
            far: Data(count: 3200),
            sampleRate: 16_000,
            to: url
        )

        let speech = ScriptedPCMTranscriber(
            near: [RawSegment(start: 0, end: 1, text: "hello priya", channel: .near)],
            far: [RawSegment(start: 1.0, end: 2.5, text: "hi lets ship the pilot", channel: .far)]
        )
        let diarizer = ScriptedDiarizer(
            clusters: [
                DiarizedCluster(
                    key: "A", ranges: [1.0...2.5], embedding: [0, 1, 0], embeddingModel: EmbeddingModel.weSpeakerV2
                )
            ]
        )
        let spine = LocalTranscriptionSpine(speech: speech, diarizer: diarizer, store: store)
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            counterpartyName: "Priya",
            audioPath: url.path,
            sttProvider: .appleSpeech
        )
        let processed = try await spine.process(
            cafURL: url,
            call: call,
            profiles: [owner, priya],
            referenceTurns: [DiarizationTurn(speaker: "A", start: 1.0, end: 2.5)]
        )

        #expect(processed.call.status == .transcribed)
        #expect(processed.call.diarizationProvider == "scripted")
        #expect(processed.turns.map(\.speakerName) == ["Me", "Priya"])
        #expect(processed.turns.map(\.text) == ["hello priya", "hi lets ship the pilot"])
        #expect(processed.der?.der == 0)
        let stored = try await store.fetchSegments(callID: call.id, provider: .appleSpeech)
        #expect(stored.map(\.text) == ["hello priya", "hi lets ship the pilot"])
        #expect(try await store.fetchCall(id: call.id)?.status == .transcribed)
    }

    @Test func committedFixtureCAFSplitsIntoNearAndFar() throws {
        guard let directory = RepoFixtures.diarizationDirectory() else {
            return
        }
        let caf = directory.appendingPathComponent("two-speaker.caf")
        guard FileManager.default.fileExists(atPath: caf.path) else {
            return
        }
        let split = try ChannelAudio.splitStereoCAF(url: caf)
        #expect(split.frameCount > 0)
        #expect(!split.near.isEmpty)
        #expect(!split.far.isEmpty)
    }

    @Test func failedDiarizationPersistsFailedCall() async throws {
        let store = MemoryStore()
        try await store.migrate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-failed-spine-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 3200),
            far: Data(count: 3200),
            sampleRate: 16_000,
            to: url
        )
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech
        )
        let spine = LocalTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 1, text: "hello", channel: .near)],
                far: []
            ),
            diarizer: FailingDiarizer(),
            store: store
        )

        do {
            _ = try await spine.process(cafURL: url, call: call, profiles: [])
            Issue.record("Expected diarization failure")
        } catch {}

        let persisted = try await store.fetchCall(id: call.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.errorStage == "diarization")
        #expect(persisted?.error?.isEmpty == false)
    }

    @Test func emptyTranscriptPersistsFailedCall() async throws {
        let store = MemoryStore()
        try await store.migrate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-empty-spine-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 3200),
            far: Data(count: 3200),
            sampleRate: 16_000,
            to: url
        )
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech
        )
        let spine = LocalTranscriptionSpine(
            speech: ScriptedPCMTranscriber(near: [], far: []),
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        )

        do {
            _ = try await spine.process(cafURL: url, call: call, profiles: [])
            Issue.record("Expected empty transcript failure")
        } catch {}

        let persisted = try await store.fetchCall(id: call.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.errorStage == "transcription")
        #expect(persisted?.error?.isEmpty == false)
    }

    @Test func spineUsesDecodedCAFSampleRate() async throws {
        let store = MemoryStore()
        try await store.migrate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-sample-rate-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 8_820),
            far: Data(count: 8_820),
            sampleRate: 44_100,
            to: url
        )
        let speech = ConfigCapturingTranscriber()
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: url.path,
            sttProvider: .appleSpeech
        )
        let spine = LocalTranscriptionSpine(
            speech: speech,
            diarizer: ScriptedDiarizer(clusters: []),
            store: store
        )

        let processed = try await spine.process(cafURL: url, call: call, profiles: [])

        #expect(await speech.sampleRates() == [44_100, 44_100])
        #expect(processed.call.sampleRate == 44_100)
        #expect(try await store.fetchCall(id: call.id)?.sampleRate == 44_100)
    }
}

private actor ConfigCapturingTranscriber: PCMTranscriber {
    nonisolated let id: STTProviderID = .appleSpeech
    nonisolated let dualInstanceMode: DualInstanceMode = .concurrentLive
    private var capturedSampleRates: [Int] = []

    func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) -> [RawSegment] {
        _ = pcm16
        capturedSampleRates.append(config.sampleRate)
        return [RawSegment(start: 0, end: 1, text: "hello", channel: channel)]
    }

    func sampleRates() -> [Int] {
        capturedSampleRates
    }
}

private struct FailingDiarizer: DiarizationService {
    let providerID = "failing"

    func diarize(fileURL: URL) async throws -> [DiarizedCluster] {
        throw Failure.diarization
    }

    private enum Failure: Error {
        case diarization
    }
}

@Suite struct PostgresStoreTests {
    @Test func emptyPasswordOmitsSecret() {
        let tcp = StoreConfiguration().clientConfiguration(password: "")
        #expect(tcp.password == nil)
        let unix = StoreConfiguration(unixSocketPath: "/tmp").clientConfiguration(password: "")
        #expect(unix.unixSocketPath == "/tmp")
        #expect(unix.password == nil)
    }

    @Test func discoversDedicatedSocketUnderConfiguredHomebrewPrefix() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-homebrew-\(UUID().uuidString)")
        let socket = prefix
            .appendingPathComponent("var/callnotes-postgresql@18/socket/.s.PGSQL.5433")
        try FileManager.default.createDirectory(
            at: socket.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: prefix) }
        #expect(FileManager.default.createFile(atPath: socket.path, contents: Data()))

        let candidates = StoreConfiguration.localCandidates(homebrewPrefixes: [prefix.path])

        #expect(candidates.map(\.unixSocketPath) == [socket.path])
        #expect(candidates.allSatisfy { $0.username == "callnotes" && $0.database == "callnotes" })
    }

    @Test func livePostgresMigratesWhenReachable() async throws {
        guard let store = await PostgresStore.makeIfAvailable() else {
            return
        }
        try await store.migrate()
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            audioPath: "/tmp/phase2.caf",
            sttProvider: .appleSpeech,
            status: .transcribed
        )
        try await store.upsertCall(call)
        #expect(try await store.fetchCall(id: call.id)?.id == call.id)
    }

    @Test func fixtureSpinePersistsAttributedSpeakersToPostgres() async throws {
        guard let store = await PostgresStore.makeIfAvailable() else {
            return
        }
        try await store.migrate()
        let owner = SpeakerIdentity.enroll(
            displayName: "Me",
            isOwner: true,
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        let priya = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [0, 1, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        try await store.upsertSpeakerProfile(owner)
        try await store.upsertSpeakerProfile(priya)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-pg-spine-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 3200),
            far: Data(count: 3200),
            sampleRate: 16_000,
            to: url
        )
        let spine = LocalTranscriptionSpine(
            speech: ScriptedPCMTranscriber(
                near: [RawSegment(start: 0, end: 1, text: "hello priya", channel: .near)],
                far: [RawSegment(start: 1.0, end: 2.5, text: "hi lets ship the pilot", channel: .far)]
            ),
            diarizer: ScriptedDiarizer(
                clusters: [
                    DiarizedCluster(
                        key: "A", ranges: [1.0...2.5], embedding: [0, 1, 0], embeddingModel: EmbeddingModel.weSpeakerV2
                    )
                ]
            ),
            store: store
        )
        let call = Call(
            source: .fileImport,
            startedAt: Date(),
            counterpartyName: "Priya",
            audioPath: url.path,
            sttProvider: .appleSpeech
        )
        let processed = try await spine.process(
            cafURL: url,
            call: call,
            profiles: [owner, priya]
        )
        #expect(processed.turns.map(\.speakerName) == ["Me", "Priya"])

        let history = try await store.fetchCalls()
        #expect(history.contains { $0.id == call.id && $0.status == .transcribed })
        let detail = try await store.fetchSegments(callID: call.id, provider: .appleSpeech)
        #expect(detail.map(\.text) == ["hello priya", "hi lets ship the pilot"])
        #expect(detail.map(\.channel) == [.near, .far])
        let speakers = try await store.fetchCallSpeakers(callID: call.id)
        #expect(speakers.contains { $0.profileID == priya.id })
    }
}
