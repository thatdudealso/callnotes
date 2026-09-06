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
        try await store.replaceCallSpeakers([
            CallSpeaker(callID: call.id, clusterKey: "me", profileID: owner.id, confidence: 1)
        ])

        let fetched = try await store.fetchCall(id: call.id)
        #expect(fetched?.id == call.id)
        #expect(try await store.fetchSegments(callID: call.id, provider: .appleSpeech).map(\.text) == ["hello"])
        #expect(try await store.fetchSpeakerProfiles().contains { $0.id == owner.id })
        #expect(try await store.fetchCallSpeakers(callID: call.id).first?.profileID == owner.id)
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
            clusters: [DiarizedCluster(key: "A", ranges: [1.0...2.5], embedding: [0, 1, 0])]
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
}

@Suite struct PostgresStoreTests {
    @Test func migrateSQLSplitsIntoStatements() {
        let statements = PostgresStore.statements(from: PostgresStore.embeddedMigrationSQL)
        #expect(statements.contains { $0.localizedCaseInsensitiveContains("create table if not exists calls") })
        #expect(statements.contains { $0.localizedCaseInsensitiveContains("speaker_profiles") })
        #expect(statements.contains { $0.localizedCaseInsensitiveContains("schema_migrations") })
    }

    @Test func emptyPasswordOmitsSecret() {
        let tcp = StoreConfiguration().clientConfiguration(password: "")
        #expect(tcp.password == nil)
        let unix = StoreConfiguration(unixSocketPath: "/tmp").clientConfiguration(password: "")
        #expect(unix.unixSocketPath == "/tmp")
        #expect(unix.password == nil)
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
                clusters: [DiarizedCluster(key: "A", ranges: [1.0...2.5], embedding: [0, 1, 0])]
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
