import Foundation
import Testing

@testable import CallNotesCore

@Suite struct DiarizationErrorRateTests {
    @Test func perfectMatchIsZero() {
        let turns = [
            DiarizationTurn(speaker: "A", start: 0, end: 1),
            DiarizationTurn(speaker: "B", start: 1, end: 2),
        ]
        let result = DiarizationErrorRate.compute(reference: turns, hypothesis: turns, collar: 0)
        #expect(result.der == 0)
        #expect(result.missedSpeech == 0)
        #expect(result.falseAlarm == 0)
        #expect(result.speakerError == 0)
    }

    @Test func missedSpeechCounts() {
        let reference = [DiarizationTurn(speaker: "A", start: 0, end: 2)]
        let hypothesis = [DiarizationTurn(speaker: "A", start: 0, end: 1)]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0
        )
        #expect(abs(result.missedSpeech - 0.5) < 0.0001)
        #expect(abs(result.der - 0.5) < 0.0001)
    }

    @Test func falseAlarmCounts() {
        let reference = [DiarizationTurn(speaker: "A", start: 0, end: 1)]
        let hypothesis = [DiarizationTurn(speaker: "A", start: 0, end: 2)]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0
        )
        #expect(abs(result.falseAlarm - 1.0) < 0.0001)
        #expect(abs(result.der - 1.0) < 0.0001)
    }

    @Test func speakerErrorAfterOptimalMapping() {
        let reference = [
            DiarizationTurn(speaker: "A", start: 0, end: 1),
            DiarizationTurn(speaker: "B", start: 1, end: 2),
        ]
        let hypothesis = [
            DiarizationTurn(speaker: "X", start: 0, end: 1),
            DiarizationTurn(speaker: "X", start: 1, end: 2),
        ]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0
        )
        #expect(result.speakerError > 0)
        #expect(result.der > 0)
    }

    @Test func splitHypothesisSpeakerCountsAsConfusion() {
        let reference = [DiarizationTurn(speaker: "A", start: 0, end: 10)]
        let hypothesis = [
            DiarizationTurn(speaker: "X", start: 0, end: 5),
            DiarizationTurn(speaker: "Y", start: 5, end: 10),
        ]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0
        )
        #expect(abs(result.speakerError - 0.5) < 0.0001)
        #expect(abs(result.der - 0.5) < 0.0001)
    }

    @Test func overlappingReferenceSpeechContributesToScoredDuration() {
        let reference = [
            DiarizationTurn(speaker: "A", start: 0, end: 2),
            DiarizationTurn(speaker: "B", start: 1, end: 2),
        ]
        let hypothesis = [DiarizationTurn(speaker: "X", start: 0, end: 2)]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0
        )
        #expect(abs(result.scoredSpeech - 3) < 0.0001)
        #expect(abs(result.missedSpeech - (1.0 / 3.0)) < 0.0001)
        #expect(abs(result.der - (1.0 / 3.0)) < 0.0001)
    }

    @Test func parseRTTMReadsSpeakerTurns() {
        let rttm = """
            SPEAKER two-speaker 1 0.000 3.000 <NA> <NA> near <NA>
            SPEAKER two-speaker 1 2.400 2.600 <NA> <NA> far <NA>
            """
        let turns = DiarizationErrorRate.parseRTTM(rttm)
        #expect(turns == [
            DiarizationTurn(speaker: "near", start: 0.0, end: 3.0),
            DiarizationTurn(speaker: "far", start: 2.4, end: 5.0),
        ])
    }

    @Test func collarTrimsBoundaries() {
        let reference = [DiarizationTurn(speaker: "A", start: 0, end: 2)]
        let hypothesis = [DiarizationTurn(speaker: "A", start: 0.1, end: 1.9)]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0.25
        )
        #expect(result.der == 0)
    }
}

@Suite struct DualInstanceProbeTests {
    @Test func bothChannelsYieldConcurrentLive() {
        #expect(DualInstanceProbe.resolve(nearStarted: true, farStarted: true) == .concurrentLive)
    }

    @Test func farFailureFallsBackToNearLiveFarBatch() {
        #expect(
            DualInstanceProbe.resolve(nearStarted: true, farStarted: false) == .nearLiveFarBatch
        )
        #expect(
            DualInstanceProbe.resolve(nearStarted: false, farStarted: false) == .nearLiveFarBatch
        )
    }
}
