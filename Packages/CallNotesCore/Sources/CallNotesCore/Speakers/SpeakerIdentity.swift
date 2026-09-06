import Foundation

/// Enrollment, match, and learn for speaker profiles (plan section 6).
///
/// Provider speaker tags are ephemeral. The embedding -> profile mapping is
/// the stable identity, so engine switches do not relabel history.
public enum SpeakerIdentity {
    public static func enroll(
        displayName: String,
        isOwner: Bool = false,
        contactIdentifier: String? = nil,
        embedding: [Float],
        embeddingModel: String,
        id: UUID = UUID()
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            displayName: displayName,
            isOwner: isOwner,
            contactIdentifier: contactIdentifier,
            centroid: embedding,
            embeddingModel: embeddingModel,
            sampleCount: 1
        )
    }

    /// Never compares vectors produced by different embedding models.
    public static func match(
        embedding: [Float],
        embeddingModel: String,
        against profiles: [SpeakerProfile]
    ) -> SpeakerMatcher.Outcome {
        let compatible = profiles.filter { $0.embeddingModel == embeddingModel }
        return SpeakerMatcher.match(embedding: embedding, against: compatible)
    }

    /// Positive samples update the centroid as a running mean. Negative
    /// samples are recorded by the caller (`speaker_samples.positive = false`)
    /// and must not pull the centroid toward the rejected voice.
    public static func learn(
        profile: SpeakerProfile,
        embedding: [Float],
        positive: Bool
    ) -> SpeakerProfile {
        guard positive, profile.centroid.count == embedding.count, profile.sampleCount > 0 else {
            return profile
        }
        var updated = profile
        let count = Float(profile.sampleCount)
        updated.centroid = zip(profile.centroid, embedding).map { old, sample in
            (old * count + sample) / (count + 1)
        }
        updated.sampleCount += 1
        return updated
    }
}
