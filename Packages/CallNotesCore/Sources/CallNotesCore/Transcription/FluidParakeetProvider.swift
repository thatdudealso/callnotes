import FluidAudio
import Foundation

/// Batch Parakeet TDT v3 engine (plan 5.3). Used for imports and re-processing.
public struct FluidParakeetProvider: STTProvider, PCMTranscriber {
    public let id: STTProviderID = .fluidParakeet
    public let supportsStreaming = false
    public let providesDiarization = false
    public let sendsAudioOffDevice = false
    public let dualInstanceMode: DualInstanceMode = .nearLiveFarBatch

    private static let models = LoadOnceCache {
        try await AsrModels.downloadAndLoad(version: .v3)
    }

    public init() {}

    public func healthCheck() async -> ProviderHealth {
        let directory = AsrModels.defaultCacheDirectory()
        return AsrModels.modelsExist(at: directory)
            ? .healthy
            : .unavailable(reason: "Parakeet models are not downloaded")
    }

    public func startSession(config: STTSessionConfig) async throws -> STTSession {
        _ = config
        throw FileImportError.streamingUnsupported
    }

    public func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] {
        let loaded = try FileAudioLoader.load(fileURL, targetSampleRate: config.sampleRate)
        if loaded.isStereo {
            let near = try await transcribePCM(loaded.near, channel: .near, config: config)
            let far = try await transcribePCM(loaded.far, channel: .far, config: config)
            return (near + far).sorted { $0.start < $1.start }
        }
        return try await transcribePCM(loaded.near, channel: .mixed, config: config)
    }

    public func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        guard !pcm16.isEmpty else { return [] }
        let models = try await Self.models.value()
        let manager = AsrManager(config: .default, models: models)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let samples = PCMResampler.int16ToFloat(
            pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        )
        let result = try await manager.transcribe(samples, decoderState: &state)
        return Self.segments(from: result, channel: channel)
    }

    static func segments(from result: ASRResult, channel: SegmentChannel) -> [RawSegment] {
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let start = words.first?.start ?? 0
        let end = words.last?.end ?? result.duration
        return [
            RawSegment(
                start: start,
                end: max(end, start),
                text: text,
                words: words.isEmpty ? nil : words,
                channel: channel
            )
        ]
    }
}
