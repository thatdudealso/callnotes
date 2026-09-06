import Testing

@testable import CallNotesCore

@Suite struct SegmentMergerTests {
    @Test func collapsesSameSpeakerWithinGap() {
        let merged = SegmentMerger.mergeAndCollapse([
            RawSegment(start: 0.0, end: 1.0, text: "hello", speakerTag: "A"),
            RawSegment(start: 1.3, end: 2.0, text: "there", speakerTag: "A"),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].text == "hello there")
        #expect(merged[0].end == 2.0)
    }

    @Test func keepsDifferentSpeakersSeparate() {
        let merged = SegmentMerger.mergeAndCollapse([
            RawSegment(start: 0.0, end: 1.0, text: "hello", speakerTag: "A"),
            RawSegment(start: 1.1, end: 2.0, text: "hi", speakerTag: "B"),
        ])
        #expect(merged.count == 2)
    }

    @Test func keepsSameSpeakerBeyondGap() {
        let merged = SegmentMerger.mergeAndCollapse([
            RawSegment(start: 0.0, end: 1.0, text: "hello", speakerTag: "A"),
            RawSegment(start: 2.5, end: 3.0, text: "again", speakerTag: "A"),
        ])
        #expect(merged.count == 2)
    }

    @Test func sortsByStartTime() {
        let merged = SegmentMerger.mergeAndCollapse([
            RawSegment(start: 5.0, end: 6.0, text: "second", speakerTag: "B"),
            RawSegment(start: 0.0, end: 1.0, text: "first", speakerTag: "A"),
        ])
        #expect(merged.map(\.text) == ["first", "second"])
    }
}
