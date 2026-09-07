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
        var refFrames = Array(repeating: Set<String>(), count: frameCount)
        var hypFrames = Array(repeating: Set<String>(), count: frameCount)
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
        for (index, speakers) in refFrames.enumerated() where !speakers.isEmpty && !excluded.contains(index) {
            scored.insert(index)
        }

        let mapping = speakerMapping(reference: refFrames, hypothesis: hypFrames, scored: scored)

        var miss = 0
        var falseAlarm = 0
        var speakerError = 0
        var scoredSpeech = 0
        for index in 0..<frameCount {
            if excluded.contains(index) { continue }
            let referenceSpeakers = refFrames[index]
            let hypothesisSpeakers = Set(hypFrames[index].map { mapping[$0] ?? $0 })
            scoredSpeech += referenceSpeakers.count
            miss += max(referenceSpeakers.count - hypothesisSpeakers.count, 0)
            falseAlarm += max(hypothesisSpeakers.count - referenceSpeakers.count, 0)
            speakerError += min(referenceSpeakers.count, hypothesisSpeakers.count)
                - referenceSpeakers.intersection(hypothesisSpeakers).count
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

    private static func fill(_ frames: inout [Set<String>], with turns: [DiarizationTurn]) {
        for turn in turns {
            let start = frameIndex(turn.start)
            let stop = max(start, frameIndex(turn.end))
            if start < frames.count {
                for index in start..<min(stop, frames.count) {
                    frames[index].insert(turn.speaker)
                }
            }
        }
    }

    private static func frameIndex(_ time: TimeInterval) -> Int {
        max(0, Int((time / frameDuration).rounded(.down)))
    }

    private static func speakerMapping(
        reference: [Set<String>],
        hypothesis: [Set<String>],
        scored: Set<Int>
    ) -> [String: String] {
        var overlap: [String: [String: Int]] = [:]
        for index in scored {
            for hypothesisSpeaker in hypothesis[index] {
                for referenceSpeaker in reference[index] {
                    overlap[hypothesisSpeaker, default: [:]][referenceSpeaker, default: 0] += 1
                }
            }
        }
        let hypotheses = Array(hypothesis.flatMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }).sorted()
        let references = Array(reference.flatMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }).sorted()
        guard !hypotheses.isEmpty, !references.isEmpty else { return [:] }

        let maximumWeight = overlap.values.flatMap(\.values).max() ?? 0
        let weights = hypotheses.map { hypothesis in
            references.map { overlap[hypothesis]?[$0] ?? 0 }
                + Array(repeating: 0, count: hypotheses.count)
        }
        let assignment = maximumWeightAssignment(weights: weights, maximumWeight: maximumWeight)
        var mapping: [String: String] = [:]
        for (row, column) in assignment.enumerated()
        where column < references.count && weights[row][column] > 0 {
            mapping[hypotheses[row]] = references[column]
        }
        return mapping
    }

    private static func maximumWeightAssignment(weights: [[Int]], maximumWeight: Int) -> [Int] {
        let rowCount = weights.count
        let columnCount = weights[0].count
        var rowPotential = Array(repeating: 0, count: rowCount + 1)
        var columnPotential = Array(repeating: 0, count: columnCount + 1)
        var columnMatch = Array(repeating: 0, count: columnCount + 1)
        var predecessor = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            columnMatch[0] = row
            var column = 0
            var minimum = Array(repeating: Int.max, count: columnCount + 1)
            var visited = Array(repeating: false, count: columnCount + 1)
            repeat {
                visited[column] = true
                let matchedRow = columnMatch[column]
                var delta = Int.max
                var nextColumn = 0
                for candidate in 1...columnCount where !visited[candidate] {
                    let cost = maximumWeight - weights[matchedRow - 1][candidate - 1]
                    let reducedCost = cost - rowPotential[matchedRow] - columnPotential[candidate]
                    if reducedCost < minimum[candidate] {
                        minimum[candidate] = reducedCost
                        predecessor[candidate] = column
                    }
                    if minimum[candidate] < delta {
                        delta = minimum[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...columnCount {
                    if visited[candidate] {
                        rowPotential[columnMatch[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else {
                        minimum[candidate] -= delta
                    }
                }
                column = nextColumn
            } while columnMatch[column] != 0

            repeat {
                let previousColumn = predecessor[column]
                columnMatch[column] = columnMatch[previousColumn]
                column = previousColumn
            } while column != 0
        }

        var assignment = Array(repeating: 0, count: rowCount)
        for column in 1...columnCount where columnMatch[column] != 0 {
            assignment[columnMatch[column] - 1] = column - 1
        }
        return assignment
    }
}
