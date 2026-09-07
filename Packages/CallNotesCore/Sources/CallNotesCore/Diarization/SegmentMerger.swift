import Foundation

/// Provider-independent merge/normalization applied after ASR (plan section 5.5).
public enum SegmentMerger {
    /// Gap below which consecutive same-speaker segments are collapsed.
    public static let collapseGapSeconds: TimeInterval = 0.8

    /// Sorts raw segments by start time and collapses consecutive segments that
    /// share a known speaker tag and are separated by less than `collapseGapSeconds`.
    public static func mergeAndCollapse(
        _ segments: [RawSegment],
        gap: TimeInterval = collapseGapSeconds
    ) -> [RawSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [RawSegment] = []
        for segment in sorted {
            if var last = result.last,
                let lastSpeakerTag = last.speakerTag,
                let segmentSpeakerTag = segment.speakerTag,
                lastSpeakerTag == segmentSpeakerTag,
                last.channel == segment.channel,
                segment.start - last.end < gap
            {
                last.end = max(last.end, segment.end)
                last.text = joinedText(last.text, segment.text)
                if let extra = segment.words {
                    last.words = (last.words ?? []) + extra
                }
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func joinedText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespaces)
        let right = rhs.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}
