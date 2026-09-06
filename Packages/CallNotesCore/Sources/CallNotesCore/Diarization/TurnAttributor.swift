import Foundation

/// Merges near/far transcript segments with diarization clusters and speaker
/// identity into attributed turns (plan 5.5 + 5.2).
public enum TurnAttributor {
    public static let ownerClusterKey = "me"

    /// Near-channel speech is always the enrolled owner. Far-channel speech is
    /// assigned to the diarized cluster with maximum temporal overlap, then
    /// matched against known profiles. Consecutive same-speaker turns with a
    /// gap under `SegmentMerger.collapseGapSeconds` are collapsed.
    public static func attribute(
        near: [RawSegment],
        far: [RawSegment],
        clusters: [DiarizedCluster],
        profiles: [SpeakerProfile],
        farLabelsAreProvisional: Bool = false
    ) -> [AttributedTurn] {
        let owner = profiles.first(where: \.isOwner)
        let clusterMatches = matchClusters(clusters, profiles: profiles)

        var tagged: [RawSegment] = []
        tagged += near.map { segment in
            var copy = snapToWords(segment)
            copy.channel = .near
            copy.speakerTag = owner.map { $0.id.uuidString } ?? ownerClusterKey
            return copy
        }
        tagged += far.map { segment in
            var copy = snapToWords(segment)
            copy.channel = .far
            let clusterKey = ClusterAssigner.assign(segment: copy, clusters: clusters)
            if let clusterKey, let match = clusterMatches[clusterKey], let profileID = match.profileID {
                copy.speakerTag = profileID.uuidString
            } else {
                copy.speakerTag = clusterKey ?? "unknown"
            }
            return copy
        }

        let merged = SegmentMerger.mergeAndCollapse(tagged)
        let unknownNames = speakerNumbers(for: clusters, profiles: profiles)

        return merged.enumerated().map { index, segment in
            let channel = segment.channel ?? (segment.speakerTag == owner?.id.uuidString ? .near : .far)
            let clusterKey: String?
            let speakerID: UUID?
            let speakerName: String
            let provisional: Bool

            if channel == .near {
                clusterKey = ownerClusterKey
                speakerID = owner?.id
                speakerName = owner?.displayName ?? "Me"
                provisional = false
            } else {
                let assigned = ClusterAssigner.assign(segment: segment, clusters: clusters)
                clusterKey = assigned
                if let assigned, let match = clusterMatches[assigned], let profileID = match.profileID,
                    let profile = profiles.first(where: { $0.id == profileID })
                {
                    speakerID = profileID
                    speakerName = profile.displayName
                } else if let assigned {
                    speakerID = nil
                    speakerName = unknownNames[assigned] ?? "Speaker \(index + 2)"
                } else {
                    speakerID = nil
                    speakerName = "Speaker \(index + 2)"
                }
                provisional = farLabelsAreProvisional
            }

            return AttributedTurn(
                start: segment.start,
                end: segment.end,
                channel: channel,
                clusterKey: clusterKey,
                speakerID: speakerID,
                speakerName: speakerName,
                isProvisional: provisional,
                text: segment.text,
                words: segment.words
            )
        }
    }

    public static func toSegments(
        _ turns: [AttributedTurn],
        callID: UUID,
        provider: STTProviderID
    ) -> [Segment] {
        turns.enumerated().map { index, turn in
            Segment(
                callID: callID,
                seq: index,
                startSec: turn.start,
                endSec: turn.end,
                channel: turn.channel,
                clusterKey: turn.clusterKey,
                text: turn.text,
                words: turn.words,
                provider: provider
            )
        }
    }

    private static func snapToWords(_ segment: RawSegment) -> RawSegment {
        guard let words = segment.words, let first = words.first, let last = words.last else {
            return segment
        }
        var copy = segment
        copy.start = first.start
        copy.end = max(first.end, last.end)
        return copy
    }

    private static func matchClusters(
        _ clusters: [DiarizedCluster],
        profiles: [SpeakerProfile]
    ) -> [String: (profileID: UUID?, similarity: Float)] {
        var result: [String: (profileID: UUID?, similarity: Float)] = [:]
        for cluster in clusters {
            guard let embedding = cluster.embedding, !embedding.isEmpty else {
                result[cluster.key] = (nil, 0)
                continue
            }
            let outcome = SpeakerIdentity.match(
                embedding: embedding,
                embeddingModel: EmbeddingModel.weSpeakerV2,
                against: profiles
            )
            switch outcome {
            case .autoLabel(let profileID, let similarity):
                result[cluster.key] = (profileID, similarity)
            case .suggest(let profileID, let similarity):
                result[cluster.key] = (profileID, similarity)
            case .unknown:
                result[cluster.key] = (nil, 0)
            }
        }
        return result
    }

    /// Unknown far clusters become "Speaker 2", "Speaker 3", ... when an owner
    /// profile exists (the owner is speaker 1). Without an owner they start at 1.
    private static func speakerNumbers(
        for clusters: [DiarizedCluster],
        profiles: [SpeakerProfile]
    ) -> [String: String] {
        let hasOwner = profiles.contains(where: \.isOwner)
        var next = hasOwner ? 2 : 1
        var names: [String: String] = [:]
        for cluster in clusters {
            let outcome: SpeakerMatcher.Outcome
            if let embedding = cluster.embedding, !embedding.isEmpty {
                outcome = SpeakerIdentity.match(
                    embedding: embedding,
                    embeddingModel: EmbeddingModel.weSpeakerV2,
                    against: profiles
                )
            } else {
                outcome = .unknown
            }
            if case .unknown = outcome {
                names[cluster.key] = "Speaker \(next)"
                next += 1
            }
        }
        return names
    }
}
