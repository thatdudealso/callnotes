import Foundation
import Testing

@testable import CallNotesCore

@Suite struct TurnAttributorTests {
    private let owner = SpeakerProfile(
        displayName: "Me",
        isOwner: true,
        centroid: [1, 0, 0],
        embeddingModel: EmbeddingModel.weSpeakerV2,
        sampleCount: 1
    )
    private let priya = SpeakerProfile(
        displayName: "Priya",
        centroid: [0, 1, 0],
        embeddingModel: EmbeddingModel.weSpeakerV2,
        sampleCount: 1
    )

    @Test func nearChannelIsAlwaysTheOwner() {
        let near = [RawSegment(start: 0, end: 1, text: "hello", channel: .near)]
        let turns = TurnAttributor.attribute(
            near: near,
            far: [],
            clusters: [],
            profiles: [owner, priya]
        )
        #expect(turns.count == 1)
        #expect(turns[0].speakerID == owner.id)
        #expect(turns[0].speakerName == "Me")
        #expect(turns[0].channel == .near)
        #expect(turns[0].isProvisional == false)
    }

    @Test func farSegmentTakesClusterWithMaxOverlapAndAutoLabels() {
        let far = [RawSegment(start: 1.0, end: 3.0, text: "hi there", channel: .far)]
        let clusters = [
            DiarizedCluster(key: "A", ranges: [1.0...3.0], embedding: [0, 1, 0])
        ]
        let turns = TurnAttributor.attribute(
            near: [],
            far: far,
            clusters: clusters,
            profiles: [owner, priya]
        )
        #expect(turns.count == 1)
        #expect(turns[0].clusterKey == "A")
        #expect(turns[0].speakerID == priya.id)
        #expect(turns[0].speakerName == "Priya")
        #expect(turns[0].channel == .far)
    }

    @Test func unknownFarClusterGetsSpeakerNumber() {
        let far = [RawSegment(start: 0, end: 1, text: "who", channel: .far)]
        let clusters = [
            DiarizedCluster(key: "Z", ranges: [0...1], embedding: [0, 0, 1])
        ]
        let turns = TurnAttributor.attribute(
            near: [],
            far: far,
            clusters: clusters,
            profiles: [owner]
        )
        #expect(turns[0].speakerID == nil)
        #expect(turns[0].speakerName == "Speaker 2")
    }

    @Test func sortsAcrossChannelsAndCollapsesSameSpeaker() {
        let near = [
            RawSegment(start: 0.0, end: 1.0, text: "hello", channel: .near),
            RawSegment(start: 1.2, end: 2.0, text: "again", channel: .near),
        ]
        let far = [
            RawSegment(start: 0.5, end: 0.9, text: "hi", channel: .far)
        ]
        let clusters = [
            DiarizedCluster(key: "A", ranges: [0.5...0.9], embedding: [0, 1, 0])
        ]
        let turns = TurnAttributor.attribute(
            near: near,
            far: far,
            clusters: clusters,
            profiles: [owner, priya]
        )
        #expect(turns.map(\.text) == ["hello", "hi", "again"])
        #expect(turns.map(\.speakerName) == ["Me", "Priya", "Me"])
    }

    @Test func snapsBoundariesToWordTimestamps() {
        let words = [
            Word(text: "hello", start: 0.12, end: 0.40),
            Word(text: "there", start: 0.41, end: 0.80),
        ]
        let near = [
            RawSegment(start: 0.0, end: 1.5, text: "hello there", words: words, channel: .near)
        ]
        let turns = TurnAttributor.attribute(
            near: near,
            far: [],
            clusters: [],
            profiles: [owner]
        )
        #expect(turns[0].start == 0.12)
        #expect(turns[0].end == 0.80)
    }

    @Test func fromStoredUsesCallSpeakerMappingNotClusterKeyAsUUID() {
        let far = Segment(
            callID: UUID(),
            seq: 0,
            startSec: 1,
            endSec: 2.5,
            channel: .far,
            clusterKey: "A",
            text: "hi lets ship the pilot",
            provider: .appleSpeech
        )
        let mapping = CallSpeaker(
            callID: far.callID,
            clusterKey: "A",
            profileID: priya.id,
            confidence: 1,
            labelOverride: "Priya"
        )
        let turns = TurnAttributor.fromStored(
            segments: [far],
            speakers: [mapping],
            profiles: [owner, priya]
        )
        #expect(turns.map(\.speakerName) == ["Priya"])
        #expect(turns.map(\.speakerID) == [priya.id])
        #expect(turns.map(\.clusterKey) == ["A"])
    }

    @Test func liveFarLabelsAreProvisional() {
        let far = [RawSegment(start: 0, end: 1, text: "live", channel: .far)]
        let clusters = [
            DiarizedCluster(key: "A", ranges: [0...1], embedding: [0, 1, 0])
        ]
        let turns = TurnAttributor.attribute(
            near: [],
            far: far,
            clusters: clusters,
            profiles: [owner, priya],
            farLabelsAreProvisional: true
        )
        #expect(turns[0].isProvisional)
    }
}
