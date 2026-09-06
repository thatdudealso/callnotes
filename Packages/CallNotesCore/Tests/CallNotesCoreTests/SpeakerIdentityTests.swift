import Foundation
import Testing

@testable import CallNotesCore

@Suite struct SpeakerIdentityTests {
    @Test func enrollStoresModelProvenance() {
        let profile = SpeakerIdentity.enroll(
            displayName: "Me",
            isOwner: true,
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        #expect(profile.isOwner)
        #expect(profile.embeddingModel == EmbeddingModel.weSpeakerV2)
        #expect(profile.sampleCount == 1)
        #expect(profile.centroid == [1, 0, 0])
    }

    @Test func learnUpdatesCentroidAsRunningMean() {
        var profile = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        profile = SpeakerIdentity.learn(profile: profile, embedding: [0, 1, 0], positive: true)
        #expect(profile.sampleCount == 2)
        #expect(profile.centroid == [0.5, 0.5, 0])
    }

    @Test func rejectDoesNotPullCentroid() {
        var profile = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        profile = SpeakerIdentity.learn(profile: profile, embedding: [0, 1, 0], positive: false)
        #expect(profile.sampleCount == 1)
        #expect(profile.centroid == [1, 0, 0])
    }

    @Test func matchSkipsDifferentEmbeddingModels() {
        let priya = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        let outcome = SpeakerIdentity.match(
            embedding: [1, 0, 0],
            embeddingModel: "other-model",
            against: [priya]
        )
        #expect(outcome == .unknown)
    }

    @Test func matchAutoLabelsSameModel() {
        let priya = SpeakerIdentity.enroll(
            displayName: "Priya",
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2
        )
        let outcome = SpeakerIdentity.match(
            embedding: [1, 0, 0],
            embeddingModel: EmbeddingModel.weSpeakerV2,
            against: [priya]
        )
        #expect(outcome == .autoLabel(profileID: priya.id, similarity: 1.0))
    }
}
