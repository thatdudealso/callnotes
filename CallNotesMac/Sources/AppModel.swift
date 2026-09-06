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
            let segments = try await store.fetchSegments(
                callID: selectedCallID,
                provider: selectedCall?.sttProvider
            )
            let profiles = try await store.fetchSpeakerProfiles()
            turnsByCall[selectedCallID] = turns(from: segments, profiles: profiles)
        }
    }

    func select(_ call: Call) async {
        selectedCallID = call.id
        do {
            let segments = try await store.fetchSegments(callID: call.id, provider: call.sttProvider)
            let profiles = try await store.fetchSpeakerProfiles()
            turnsByCall[call.id] = turns(from: segments, profiles: profiles)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func processSampleCall() async {
        recordingState = .processing
        statusMessage = "Processing sample call..."
        live.lastLine = "Processing sample call..."
        defer { recordingState = .idle }

        do {
            let fixture = try SampleCallFixture.materialize()
            var profiles = try await store.fetchSpeakerProfiles()
            if !profiles.contains(where: \.isOwner) {
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
                profiles = [owner, priya]
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
            live = LiveTranscriptState(
                engine: .appleSpeech,
                elapsed: TimeInterval(processed.call.durationSec ?? 0),
                currentSpeakerName: processed.turns.last?.speakerName ?? "Me",
                lastLine: processed.turns.last?.text ?? "",
                isProvisionalSpeaker: false,
                dualInstanceMode: processed.dualInstanceMode
            )
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

    private func turns(from segments: [Segment], profiles: [SpeakerProfile]) -> [AttributedTurn] {
        let owner = profiles.first(where: \.isOwner)
        return segments.map { segment in
            let profile = profiles.first { $0.id.uuidString == segment.clusterKey }
                ?? (segment.channel == .near ? owner : nil)
            let name: String
            if let profile {
                name = profile.displayName
            } else if segment.channel == .near {
                name = "Me"
            } else {
                name = segment.clusterKey.map { "Speaker \($0)" } ?? "Speaker 2"
            }
            return AttributedTurn(
                start: segment.startSec,
                end: segment.endSec,
                channel: segment.channel,
                clusterKey: segment.clusterKey,
                speakerID: profile?.id,
                speakerName: name,
                isProvisional: false,
                text: segment.text,
                words: segment.words
            )
        }
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
                DiarizedCluster(key: "A", ranges: [2.4...5.0], embedding: [0, 1, 0])
            ]
        )
    }

    static func materialize() throws -> (cafURL: URL, referenceTurns: [DiarizationTurn]) {
        if let bundled = Bundle.main.url(
            forResource: "two-speaker",
            withExtension: "caf",
            subdirectory: "diarization"
        ) ?? Bundle.main.url(forResource: "two-speaker", withExtension: "caf") {
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
