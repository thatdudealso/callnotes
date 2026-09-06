import CallNotesCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var recordingState: RecordingState = .idle
    var calls: [Call] = []
    var selectedCallID: UUID?
    var turnsByCall: [UUID: [AttributedTurn]] = [:]
    var live: LiveTranscriptState = LiveTranscriptState()
    var storeBackendName = "memory"
    var lastDER: DiarizationErrorRate.Result?
    var statusMessage: String?

    private var store: any CallStore
    private var speech = AppleSpeechProvider()
    private let memoryStore = MemoryStore()
    private var liveSession: (any STTSession)?
    private var liveResultsTask: Task<Void, Never>?
    private var fixturePlaybackTask: Task<Void, Never>?

    var selectedCall: Call? {
        calls.first { $0.id == selectedCallID }
    }

    var selectedTurns: [AttributedTurn] {
        guard let selectedCallID else { return [] }
        return turnsByCall[selectedCallID] ?? []
    }

    init() {
        self.store = memoryStore
        Task { await bootstrap() }
    }

    func bootstrap() async {
        if let postgres = await PostgresStore.makeIfAvailable() {
            store = postgres
            storeBackendName = "postgres"
        } else {
            store = memoryStore
            storeBackendName = "memory"
        }
        do {
            try await store.migrate()
            speech = await AppleSpeechProvider.validated()
            live.dualInstanceMode = speech.dualInstanceMode
            try await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refresh() async throws {
        calls = try await store.fetchCalls()
        if selectedCallID == nil {
            selectedCallID = calls.first?.id
        }
        if let selectedCallID {
            turnsByCall[selectedCallID] = try await loadTurns(callID: selectedCallID)
        }
    }

    func select(_ call: Call) async {
        selectedCallID = call.id
        do {
            turnsByCall[call.id] = try await loadTurns(callID: call.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func processSampleCall() async {
        recordingState = .processing
        statusMessage = "Processing sample call..."
        live.lastLine = "Processing sample call..."

        do {
            let fixture = try SampleCallFixture.materialize()
            do {
                try await startLiveSession()
                startFixturePlayback(cafURL: fixture.cafURL)
            } catch {
                live.lastLine = "Processing sample call..."
            }
            var profiles = try await store.fetchSpeakerProfiles()
            if !profiles.contains(where: \.isOwner) {
                let owner = SpeakerIdentity.enroll(
                    displayName: "Me",
                    isOwner: true,
                    embedding: SampleCallFixture.embedding([1, 0, 0]),
                    embeddingModel: EmbeddingModel.weSpeakerV2
                )
                try await store.upsertSpeakerProfile(owner)
                profiles.append(owner)
            }
            let priyaEmbedding = SampleCallFixture.embedding([0, 1, 0])
            if !profiles.contains(where: {
                $0.displayName == "Priya"
                    && $0.embeddingModel == EmbeddingModel.weSpeakerV2
                    && $0.centroid == priyaEmbedding
            }) {
                let priya = SpeakerIdentity.enroll(
                    displayName: "Priya",
                    embedding: priyaEmbedding,
                    embeddingModel: EmbeddingModel.weSpeakerV2
                )
                try await store.upsertSpeakerProfile(priya)
                profiles.append(priya)
            }

            let call = Call(
                source: .fileImport,
                startedAt: Date(),
                counterpartyName: "Priya",
                audioPath: fixture.cafURL.path,
                sttProvider: .appleSpeech,
                status: .transcribing
            )

            let processed: ProcessedCall
            if let hardware = await processWithLocalEngine(cafURL: fixture.cafURL, call: call, profiles: profiles) {
                processed = hardware
            } else {
                let spine = LocalTranscriptionSpine(
                    speech: SampleCallFixture.scriptedSpeech,
                    diarizer: SampleCallFixture.scriptedDiarizer,
                    store: store
                )
                processed = try await spine.process(
                    cafURL: fixture.cafURL,
                    call: call,
                    profiles: profiles,
                    referenceTurns: fixture.referenceTurns
                )
            }

            turnsByCall[processed.call.id] = processed.turns
            lastDER = processed.der
            live.engine = .appleSpeech
            live.elapsed = TimeInterval(processed.call.durationSec ?? 0)
            live.currentSpeakerName = processed.turns.last?.speakerName ?? "Me"
            if live.lastLine.isEmpty || live.lastLine == "Processing sample call..." {
                live.lastLine = processed.turns.last?.text ?? ""
            }
            live.isProvisionalSpeaker = false
            live.dualInstanceMode = processed.dualInstanceMode
            selectedCallID = processed.call.id
            try await refresh()
            let derText: String
            if let der = processed.der {
                derText = String(format: "DER %.1f%% (target %.1f%%)", der.der * 100, DiarizationErrorRate.initialTarget * 100)
            } else {
                derText = "DER not scored"
            }
            statusMessage = "Sample call stored in \(storeBackendName). \(derText)"
        } catch {
            statusMessage = error.localizedDescription
            recordingState = .idle
        }
    }

    func startLiveSession() async throws {
        if liveSession != nil {
            return
        }
        let session = try await speech.startSession(config: STTSessionConfig())
        liveSession = session
        recordingState = .recording
        liveResultsTask = Task { [weak self] in
            do {
                for try await segment in session.results {
                    guard !Task.isCancelled, let self else { return }
                    live.elapsed = max(live.elapsed, segment.end)
                    live.currentSpeakerName = segment.channel == .far ? "Speaker 2" : "Me"
                    live.lastLine = segment.text
                    live.isProvisionalSpeaker = segment.channel == .far || segment.isVolatile
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    func appendLivePCM(_ pcm: Data) async throws {
        try await liveSession?.append(pcm: pcm)
    }

    func finishLiveSession() async {
        defer {
            liveSession = nil
            liveResultsTask = nil
            recordingState = .idle
        }
        do {
            try await liveSession?.finish()
        } catch {
            statusMessage = error.localizedDescription
        }
        liveResultsTask?.cancel()
    }

    func stopLiveSession() async {
        fixturePlaybackTask?.cancel()
        fixturePlaybackTask = nil
        await finishLiveSession()
    }

    private func startFixturePlayback(cafURL: URL) {
        fixturePlaybackTask?.cancel()
        fixturePlaybackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let split = try ChannelAudio.splitStereoCAF(url: cafURL)
                let chunkSize = 8_000
                for offset in stride(from: 0, to: split.near.count, by: chunkSize) {
                    guard !Task.isCancelled else { return }
                    let end = min(offset + chunkSize, split.near.count)
                    try await appendLivePCM(split.near.subdata(in: offset..<end))
                    try await Task.sleep(for: .milliseconds(100))
                }
                await finishLiveSession()
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = error.localizedDescription
                await finishLiveSession()
            }
        }
    }

    private func processWithLocalEngine(
        cafURL: URL,
        call: Call,
        profiles: [SpeakerProfile]
    ) async -> ProcessedCall? {
        do {
            let spine = LocalTranscriptionSpine(
                speech: speech,
                diarizer: FluidDiarizer(),
                store: store
            )
            let processed = try await spine.process(
                cafURL: cafURL,
                call: call,
                profiles: profiles,
                referenceTurns: SampleCallFixture.referenceTurns
            )
            if processed.turns.contains(where: { !$0.text.isEmpty }) {
                return processed
            }
            return nil
        } catch {
            return nil
        }
    }

    private func loadTurns(callID: UUID) async throws -> [AttributedTurn] {
        let provider = calls.first { $0.id == callID }?.sttProvider
        let segments = try await store.fetchSegments(callID: callID, provider: provider)
        let speakers = try await store.fetchCallSpeakers(callID: callID)
        let profiles = try await store.fetchSpeakerProfiles()
        return TurnAttributor.fromStored(segments: segments, speakers: speakers, profiles: profiles)
    }
}

enum SampleCallFixture {
    static let referenceTurns = [
        DiarizationTurn(speaker: "A", start: 2.4, end: 5.0),
    ]

    static var scriptedSpeech: ScriptedPCMTranscriber {
        ScriptedPCMTranscriber(
            near: [
                RawSegment(
                    start: 0.0,
                    end: 2.2,
                    text: "Hello Priya, this is the near channel confirming the meeting time.",
                    channel: .near
                )
            ],
            far: [
                RawSegment(
                    start: 2.4,
                    end: 5.0,
                    text: "Hi, this is Priya on the far channel. Let's ship the pilot next week.",
                    channel: .far
                )
            ]
        )
    }

    static var scriptedDiarizer: ScriptedDiarizer {
        ScriptedDiarizer(
            clusters: [
                DiarizedCluster(
                    key: "A",
                    ranges: [2.4...5.0],
                    embedding: embedding([0, 1, 0])
                )
            ]
        )
    }

    static func embedding(_ values: [Float]) -> [Float] {
        values + Array(repeating: 0, count: max(EmbeddingModel.dimension - values.count, 0))
    }

    static func materialize() throws -> (cafURL: URL, referenceTurns: [DiarizationTurn]) {
        let bundled =
            Bundle.main.url(forResource: "two-speaker", withExtension: "caf", subdirectory: "diarization")
            ?? Bundle.main.url(
                forResource: "two-speaker",
                withExtension: "caf",
                subdirectory: "Fixtures/diarization"
            )
            ?? Bundle.main.url(forResource: "two-speaker", withExtension: "caf")
        if let bundled {
            return (bundled, referenceTurns)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-two-speaker.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try ChannelAudio.writeStereoCAF(
                near: tone(frequency: 440, seconds: 3),
                far: tone(frequency: 660, seconds: 3),
                sampleRate: 16_000,
                to: url
            )
        }
        return (url, referenceTurns)
    }

    private static func tone(frequency: Double, seconds: Double, sampleRate: Double = 16_000) -> Data {
        let count = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = sin(2 * Double.pi * frequency * Double(index) / sampleRate)
            samples[index] = Int16((value * 0.2) * Double(Int16.max))
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
