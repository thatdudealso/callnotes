import Foundation
import Testing

@testable import CallNotesCore

@Suite struct SpeakerMatcherTests {
    private func profile(_ name: String, _ centroid: [Float]) -> SpeakerProfile {
        SpeakerProfile(displayName: name, centroid: centroid, embeddingModel: "wespeaker-test")
    }

    @Test func identicalVectorAutoLabels() {
        let priya = profile("Priya", [1, 0, 0])
        let outcome = SpeakerMatcher.match(embedding: [1, 0, 0], against: [priya])
        #expect(outcome == .autoLabel(profileID: priya.id, similarity: 1.0))
    }

    @Test func orthogonalVectorIsUnknown() {
        let priya = profile("Priya", [1, 0, 0])
        let outcome = SpeakerMatcher.match(embedding: [0, 1, 0], against: [priya])
        #expect(outcome == .unknown)
    }

    @Test func midSimilaritySuggests() {
        let priya = profile("Priya", [1, 0, 0])
        // cos = 0.6: inside the suggest band [0.55, 0.70)
        let outcome = SpeakerMatcher.match(embedding: [0.6, 0.8, 0], against: [priya])
        guard case .suggest(let id, _) = outcome else {
            Issue.record("expected .suggest, got \(outcome)")
            return
        }
        #expect(id == priya.id)
    }

    @Test func mismatchedDimensionsAreSkipped() {
        let short = profile("Short", [1, 0])
        let outcome = SpeakerMatcher.match(embedding: [1, 0, 0], against: [short])
        #expect(outcome == .unknown)
    }
}

@Suite struct ClusterAssignerTests {
    @Test func assignsToClusterWithMaxOverlap() {
        let clusters = [
            DiarizedCluster(key: "A", ranges: [0.0...2.0]),
            DiarizedCluster(key: "B", ranges: [2.0...10.0]),
        ]
        let segment = RawSegment(start: 1.5, end: 5.0, text: "mostly B")
        #expect(ClusterAssigner.assign(segment: segment, clusters: clusters) == "B")
    }

    @Test func noOverlapReturnsNil() {
        let clusters = [DiarizedCluster(key: "A", ranges: [10.0...12.0])]
        let segment = RawSegment(start: 0.0, end: 1.0, text: "silence zone")
        #expect(ClusterAssigner.assign(segment: segment, clusters: clusters) == nil)
    }
}
