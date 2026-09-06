import FluidAudio
import Foundation

/// FluidAudio-backed diarization (plan 5.2 / 6).
///
/// The offline VBx pass is the source of truth for identity. LS-EEND
/// streaming labels are provisional and overwritten after hang-up.
public struct FluidDiarizer: DiarizationService {
    public static let providerID = "fluid_audio"

    public var providerID: String { Self.providerID }

    public init() {}

    public func diarize(fileURL: URL) async throws -> [DiarizedCluster] {
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        let result = try await manager.process(fileURL)
        return clusters(from: result)
    }

    /// Provisional far-channel labels for the live pill. Overwritten by `diarize`.
    public func diarizeLive(samples: [Float], sampleRate: Double) async throws -> [DiarizedCluster] {
        let diarizer = LSEENDDiarizer()
        try await diarizer.initialize(variant: .dihard3)
        let timeline = try diarizer.processComplete(
            samples,
            sourceSampleRate: sampleRate
        )
        return clusters(from: timeline)
    }

    public func enrollEmbedding(samples: [Float]) async throws -> [Float] {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    public func embeddingModelID() -> String {
        EmbeddingModel.weSpeakerV2
    }

    private func clusters(from result: DiarizationResult) -> [DiarizedCluster] {
        var ranges: [String: [ClosedRange<TimeInterval>]] = [:]
        var embeddings: [String: [Float]] = result.speakerDatabase ?? [:]
        for segment in result.segments {
            let range = TimeInterval(segment.startTimeSeconds)...TimeInterval(segment.endTimeSeconds)
            ranges[segment.speakerId, default: []].append(range)
            if embeddings[segment.speakerId] == nil, !segment.embedding.isEmpty {
                embeddings[segment.speakerId] = segment.embedding
            }
        }
        return ranges.keys.sorted().map { key in
            DiarizedCluster(key: key, ranges: ranges[key] ?? [], embedding: embeddings[key])
        }
    }

    private func clusters(from timeline: DiarizerTimeline) -> [DiarizedCluster] {
        var ranges: [String: [ClosedRange<TimeInterval>]] = [:]
        for speaker in timeline.speakers.values {
            let key = speaker.name ?? "S\(speaker.index)"
            let segments = speaker.finalizedSegments + speaker.tentativeSegments
            for segment in segments {
                let range = TimeInterval(segment.startTime)...TimeInterval(segment.endTime)
                ranges[key, default: []].append(range)
            }
        }
        return ranges.keys.sorted().map { key in
            DiarizedCluster(key: key, ranges: ranges[key] ?? [], embedding: nil)
        }
    }
}
