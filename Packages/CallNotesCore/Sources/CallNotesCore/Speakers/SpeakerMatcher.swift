import Foundation

/// Cosine-similarity matching of diarized-cluster embeddings against known
/// speaker profiles (plan section 6.2). Thresholds are initial values to be
/// tuned on real calls.
public enum SpeakerMatcher {
    public static let autoLabelThreshold: Float = 0.70
    public static let suggestThreshold: Float = 0.55

    public enum Outcome: Equatable, Sendable {
        case autoLabel(profileID: UUID, similarity: Float)
        case suggest(profileID: UUID, similarity: Float)
        case unknown
    }

    /// Never compare vectors produced by different embedding models or
    /// dimensions; callers must pre-filter profiles to the query's model.
    public static func match(
        embedding: [Float],
        against profiles: [SpeakerProfile]
    ) -> Outcome {
        var best: (profile: SpeakerProfile, similarity: Float)?
        for profile in profiles where profile.centroid.count == embedding.count {
            let similarity = cosineSimilarity(embedding, profile.centroid)
            if similarity > (best?.similarity ?? -1) {
                best = (profile, similarity)
            }
        }
        guard let best else { return .unknown }
        if best.similarity >= autoLabelThreshold {
            return .autoLabel(profileID: best.profile.id, similarity: best.similarity)
        }
        if best.similarity >= suggestThreshold {
            return .suggest(profileID: best.profile.id, similarity: best.similarity)
        }
        return .unknown
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "embedding dimensions must match")
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }
}
