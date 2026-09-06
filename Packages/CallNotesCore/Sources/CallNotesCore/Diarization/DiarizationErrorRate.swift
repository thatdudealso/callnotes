import Foundation

/// One speaker turn used as DER reference or hypothesis.
public struct DiarizationTurn: Sendable, Equatable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Frame-based Diarization Error Rate (plan 16.4).
///
/// DER = (missed speech + false alarm + speaker error) / scored reference speech.
/// A collar around each reference boundary is excluded from scoring, matching
/// the standard NIST/pyannote evaluation collar.
public enum DiarizationErrorRate {
    public struct Result: Sendable, Equatable {
        public var der: Double
        public var missedSpeech: Double
        public var falseAlarm: Double
        public var speakerError: Double
        public var scoredSpeech: Double

        public init(
            der: Double,
            missedSpeech: Double,
            falseAlarm: Double,
            speakerError: Double,
            scoredSpeech: Double
        ) {
            self.der = der
            self.missedSpeech = missedSpeech
            self.falseAlarm = falseAlarm
            self.speakerError = speakerError
            self.scoredSpeech = scoredSpeech
        }
    }

    /// Initial fixture-set target: FluidAudio's published AMI offline DER.
    /// Clean synthetic fixtures are expected to beat this by a wide margin.
    public static let initialTarget = 0.177

    public static let defaultCollar: TimeInterval = 0.25
    public static let frameDuration: TimeInterval = 0.01

    public static func compute(
        reference: [DiarizationTurn],
        hypothesis: [DiarizationTurn],
        collar: TimeInterval = defaultCollar
    ) -> Result {
        let end = max(
            reference.map(\.end).max() ?? 0,
            hypothesis.map(\.end).max() ?? 0
        )
        guard end > 0 else {
            return Result(der: 0, missedSpeech: 0, falseAlarm: 0, speakerError: 0, scoredSpeech: 0)
        }

        let frameCount = Int((end / frameDuration).rounded(.up))
        var refFrames = Array(repeating: Optional<String>.none, count: frameCount)
        var hypFrames = Array(repeating: Optional<String>.none, count: frameCount)
        fill(&refFrames, with: reference)
        fill(&hypFrames, with: hypothesis)

        var excluded = Set<Int>()
        if collar > 0 {
            let collarFrames = Int((collar / frameDuration).rounded(.up))
            for turn in reference {
                let start = frameIndex(turn.start)
                let stop = frameIndex(turn.end)
                for index in max(0, start - collarFrames)..<min(frameCount, start + collarFrames) {
                    excluded.insert(index)
                }
                for index in max(0, stop - collarFrames)..<min(frameCount, stop + collarFrames) {
                    excluded.insert(index)
                }
            }
        }

        var scored = Set<Int>()
        for (index, speaker) in refFrames.enumerated() where speaker != nil && !excluded.contains(index) {
            scored.insert(index)
        }

        let mapping = speakerMapping(reference: refFrames, hypothesis: hypFrames, scored: scored)

        var miss = 0
        var falseAlarm = 0
        var speakerError = 0
        var scoredSpeech = 0
        for index in 0..<frameCount {
            if excluded.contains(index) { continue }
            let ref = refFrames[index]
            let hyp = hypFrames[index].flatMap { mapping[$0] }
            if ref != nil { scoredSpeech += 1 }
            switch (ref, hyp) {
            case (nil, .some):
                falseAlarm += 1
            case (.some, nil):
                miss += 1
            case let (.some(refSpeaker), .some(hypSpeaker)) where refSpeaker != hypSpeaker:
                speakerError += 1
            default:
                break
            }
        }

        let scoredSpeechTime = Double(max(scoredSpeech, 1)) * frameDuration
        let missRate = Double(miss) * frameDuration / scoredSpeechTime
        let faRate = Double(falseAlarm) * frameDuration / scoredSpeechTime
        let seRate = Double(speakerError) * frameDuration / scoredSpeechTime
        return Result(
            der: missRate + faRate + seRate,
            missedSpeech: missRate,
            falseAlarm: faRate,
            speakerError: seRate,
            scoredSpeech: Double(scoredSpeech) * frameDuration
        )
    }

    /// Parses NIST RTTM (`SPEAKER <file> 1 <start> <dur> <NA> <NA> <spk> <NA>`).
    public static func parseRTTM(_ text: String) -> [DiarizationTurn] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 8, parts[0] == "SPEAKER",
                let start = TimeInterval(parts[3]),
                let duration = TimeInterval(parts[4])
            else {
                return nil
            }
            return DiarizationTurn(speaker: parts[7], start: start, end: start + duration)
        }
    }

    public static func turns(from clusters: [DiarizedCluster]) -> [DiarizationTurn] {
        clusters.flatMap { cluster in
            cluster.ranges.map {
                DiarizationTurn(speaker: cluster.key, start: $0.lowerBound, end: $0.upperBound)
            }
        }
    }

    public static func turns(from attributed: [AttributedTurn]) -> [DiarizationTurn] {
        attributed.map {
            DiarizationTurn(speaker: $0.speakerName, start: $0.start, end: $0.end)
        }
    }

    private static func fill(_ frames: inout [String?], with turns: [DiarizationTurn]) {
        for turn in turns {
            let start = frameIndex(turn.start)
            let stop = max(start, frameIndex(turn.end))
            if start < frames.count {
                for index in start..<min(stop, frames.count) {
                    frames[index] = turn.speaker
                }
            }
        }
    }

    private static func frameIndex(_ time: TimeInterval) -> Int {
        max(0, Int((time / frameDuration).rounded(.down)))
    }

    /// Greedy many-to-one mapping of hypothesis speakers onto reference speakers
    /// by overlapping scored frames.
    private static func speakerMapping(
        reference: [String?],
        hypothesis: [String?],
        scored: Set<Int>
    ) -> [String: String] {
        var overlap: [String: [String: Int]] = [:]
        for index in scored {
            guard let hyp = hypothesis[index], let ref = reference[index] else { continue }
            overlap[hyp, default: [:]][ref, default: 0] += 1
        }
        var mapping: [String: String] = [:]
        let hypSpeakers = Set(hypothesis.compactMap { $0 })
        for hyp in hypSpeakers {
            if let best = overlap[hyp]?.max(by: { $0.value < $1.value })?.key {
                mapping[hyp] = best
            } else {
                mapping[hyp] = hyp
            }
        }
        return mapping
    }
}
