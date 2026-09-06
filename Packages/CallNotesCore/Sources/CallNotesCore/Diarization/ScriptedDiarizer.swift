import Foundation

/// Test/harness diarizer that returns scripted clusters, used when FluidAudio
/// models are not present (CI) and as a seam for identity tests.
public struct ScriptedDiarizer: DiarizationService {
    public var clusters: [DiarizedCluster]

    public init(clusters: [DiarizedCluster]) {
        self.clusters = clusters
    }

    public func diarize(fileURL: URL) async throws -> [DiarizedCluster] {
        _ = fileURL
        return clusters
    }
}

/// Deterministic PCM transcriber used by the fixture spine in CI.
public struct ScriptedPCMTranscriber: PCMTranscriber {
    public let id: STTProviderID = .appleSpeech
    public var dualInstanceMode: DualInstanceMode
    public var near: [RawSegment]
    public var far: [RawSegment]

    public init(
        near: [RawSegment],
        far: [RawSegment],
        dualInstanceMode: DualInstanceMode = .concurrentLive
    ) {
        self.near = near
        self.far = far
        self.dualInstanceMode = dualInstanceMode
    }

    public func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        _ = pcm16
        _ = config
        return channel == .far ? far : near
    }
}
