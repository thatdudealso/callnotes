import Foundation

/// Result of running the Phase 2 local spine on a 2-channel CAF.
public struct ProcessedCall: Sendable {
    public var call: Call
    public var turns: [AttributedTurn]
    public var clusters: [DiarizedCluster]
    public var dualInstanceMode: DualInstanceMode
    public var der: DiarizationErrorRate.Result?

    public init(
        call: Call,
        turns: [AttributedTurn],
        clusters: [DiarizedCluster],
        dualInstanceMode: DualInstanceMode,
        der: DiarizationErrorRate.Result? = nil
    ) {
        self.call = call
        self.turns = turns
        self.clusters = clusters
        self.dualInstanceMode = dualInstanceMode
        self.der = der
    }
}

/// Live pill state bound to partial SpeechAnalyzer results.
public struct LiveTranscriptState: Sendable, Equatable {
    public var engine: STTProviderID
    public var elapsed: TimeInterval
    public var currentSpeakerName: String
    public var lastLine: String
    public var isOffDevice: Bool
    public var isProvisionalSpeaker: Bool
    public var dualInstanceMode: DualInstanceMode

    public init(
        engine: STTProviderID = .appleSpeech,
        elapsed: TimeInterval = 0,
        currentSpeakerName: String = "Me",
        lastLine: String = "",
        isOffDevice: Bool = false,
        isProvisionalSpeaker: Bool = false,
        dualInstanceMode: DualInstanceMode = .concurrentLive
    ) {
        self.engine = engine
        self.elapsed = elapsed
        self.currentSpeakerName = currentSpeakerName
        self.lastLine = lastLine
        self.isOffDevice = isOffDevice
        self.isProvisionalSpeaker = isProvisionalSpeaker
        self.dualInstanceMode = dualInstanceMode
    }
}

/// PCM transcriber used by the spine so tests can inject scripted ASR.
public protocol PCMTranscriber: Sendable {
    var id: STTProviderID { get }
    var dualInstanceMode: DualInstanceMode { get }
    func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment]
}

extension AppleSpeechProvider: PCMTranscriber {}

/// CAF -> SpeechAnalyzer -> FluidAudio identity -> Postgres (plan Phase 2 spine).
///
/// Capture is owned by Phase 1; this pipeline accepts a fixture (or captured)
/// 2-channel CAF with L = near, R = far.
public struct LocalTranscriptionSpine: Sendable {
    public var speech: any PCMTranscriber
    public var diarizer: any DiarizationService
    public var store: any CallStore
    public var liveDiarizer: (any LiveDiarizationService)?

    public init(
        speech: any PCMTranscriber,
        diarizer: any DiarizationService,
        store: any CallStore,
        liveDiarizer: (any LiveDiarizationService)? = nil
    ) {
        self.speech = speech
        self.diarizer = diarizer
        self.store = store
        self.liveDiarizer = liveDiarizer
    }

    public func process(
        cafURL: URL,
        call: Call,
        profiles: [SpeakerProfile],
        referenceTurns: [DiarizationTurn] = []
    ) async throws -> ProcessedCall {
        var working = call
        working.status = .transcribing
        working.sttProvider = speech.id
        working.diarizationProvider = FluidDiarizer.providerID
        working.audioPath = cafURL.path
        try await store.upsertCall(working)

        let config = STTSessionConfig(sampleRate: working.sampleRate)
        let split = try ChannelAudio.splitStereoCAF(url: cafURL)
        let near: [RawSegment]
        let far: [RawSegment]
        switch speech.dualInstanceMode {
        case .concurrentLive:
            async let nearTask = speech.transcribePCM(split.near, channel: .near, config: config)
            async let farTask = speech.transcribePCM(split.far, channel: .far, config: config)
            near = try await nearTask
            far = try await farTask
        case .nearLiveFarBatch:
            near = try await speech.transcribePCM(split.near, channel: .near, config: config)
            far = try await speech.transcribePCM(split.far, channel: .far, config: config)
        }

        let farURL = cafURL.deletingLastPathComponent()
            .appendingPathComponent("\(working.id.uuidString)-far.caf")
        try ChannelAudio.writeMonoCAF(pcm16: split.far, sampleRate: split.sampleRate, to: farURL)
        let clusters = try await diarizer.diarize(fileURL: farURL)

        let turns = TurnAttributor.attribute(
            near: near,
            far: far,
            clusters: clusters,
            profiles: profiles
        )
        let segments = TurnAttributor.toSegments(turns, callID: working.id, provider: speech.id)
        try await store.replaceSegments(callID: working.id, provider: speech.id, segments)

        let mappings = clusters.map { cluster -> CallSpeaker in
            let match = turns.first { $0.clusterKey == cluster.key }
            return CallSpeaker(
                callID: working.id,
                clusterKey: cluster.key,
                profileID: match?.speakerID,
                confidence: match?.speakerID == nil ? 0 : 1,
                labelOverride: match?.speakerName
            )
        }
        try await store.replaceCallSpeakers(mappings)

        working.status = .transcribed
        working.endedAt = working.endedAt ?? Date()
        if working.durationSec == nil {
            let last = turns.map(\.end).max() ?? 0
            working.durationSec = Int(last.rounded())
        }
        try await store.upsertCall(working)

        let der: DiarizationErrorRate.Result?
        if !referenceTurns.isEmpty {
            der = DiarizationErrorRate.compute(
                reference: referenceTurns,
                hypothesis: DiarizationErrorRate.turns(from: clusters),
                collar: DiarizationErrorRate.defaultCollar
            )
        } else {
            der = nil
        }

        return ProcessedCall(
            call: working,
            turns: turns,
            clusters: clusters,
            dualInstanceMode: speech.dualInstanceMode,
            der: der
        )
    }
}

/// Optional streaming diarization used only for live provisional labels.
public protocol LiveDiarizationService: Sendable {
    func diarizeLive(samples: [Float], sampleRate: Double) async throws -> [DiarizedCluster]
}

extension FluidDiarizer: LiveDiarizationService {}
