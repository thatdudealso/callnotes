import Foundation

/// One diarized cluster of speech from the far channel.
public struct DiarizedCluster: Sendable, Equatable {
    public var key: String
    public var ranges: [ClosedRange<TimeInterval>]
    public var embedding: [Float]?

    public init(key: String, ranges: [ClosedRange<TimeInterval>], embedding: [Float]? = nil) {
        self.key = key
        self.ranges = ranges
        self.embedding = embedding
    }
}

/// Batch diarization of the far channel; the FluidAudio-backed implementation
/// arrives in Phase 2. The batch pass is the source of truth for identity;
/// streaming (LS-EEND / Sortformer) labels are provisional.
public protocol DiarizationService: Sendable {
    var providerID: String { get }
    func diarize(fileURL: URL) async throws -> [DiarizedCluster]
}

/// Assigns each far-channel segment to the cluster with maximum temporal overlap.
public enum ClusterAssigner {
    public static func assign(
        segment: RawSegment,
        clusters: [DiarizedCluster]
    ) -> String? {
        var bestKey: String?
        var bestOverlap: TimeInterval = 0
        for cluster in clusters {
            var overlap: TimeInterval = 0
            for range in cluster.ranges {
                let start = max(segment.start, range.lowerBound)
                let end = min(segment.end, range.upperBound)
                if end > start { overlap += end - start }
            }
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestKey = cluster.key
            }
        }
        return bestKey
    }
}
