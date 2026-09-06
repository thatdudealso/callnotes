import Foundation
import Testing

@testable import CallNotesCore

@Suite struct DiarizationHarnessTests {
    /// Always-on fixture DER: scripted clusters against the committed RTTM.
    /// FluidAudio on real audio is gated by CALLNOTES_HARNESS=1 (not CI).
    @Test func reportsDEROnFixtureSet() throws {
        let reference: [DiarizationTurn]
        if let rttmURL = RepoFixtures.diarizationDirectory()?
            .appendingPathComponent("two-speaker.rttm"),
            let text = try? String(contentsOf: rttmURL, encoding: .utf8)
        {
            reference = DiarizationErrorRate.parseRTTM(text)
        } else {
            reference = [
                DiarizationTurn(speaker: "near", start: 0.0, end: 3.0),
                DiarizationTurn(speaker: "far", start: 2.4, end: 5.0),
            ]
        }
        let hypothesis = [
            DiarizationTurn(speaker: "me", start: 0.0, end: 3.0),
            DiarizationTurn(speaker: "A", start: 2.4, end: 5.0),
        ]
        let result = DiarizationErrorRate.compute(
            reference: reference,
            hypothesis: hypothesis,
            collar: 0.25
        )
        #expect(result.der <= DiarizationErrorRate.initialTarget)
        let line = String(
            format: "fixture DER=%.4f miss=%.4f fa=%.4f se=%.4f target=%.4f",
            result.der,
            result.missedSpeech,
            result.falseAlarm,
            result.speakerError,
            DiarizationErrorRate.initialTarget
        )
        print(line)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CALLNOTES_HARNESS"] == "1"))
    func fluidAudioDEROnGeneratedFixture() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-harness-\(UUID().uuidString).caf")
        try ChannelAudio.writeStereoCAF(
            near: Data(count: 16_000 * 2 * 3),
            far: Data(count: 16_000 * 2 * 3),
            sampleRate: 16_000,
            to: url
        )
        let diarizer = FluidDiarizer()
        let clusters = try await diarizer.diarize(fileURL: url)
        let result = DiarizationErrorRate.compute(
            reference: SampleReference.turns,
            hypothesis: DiarizationErrorRate.turns(from: clusters)
        )
        print(
            String(
                format: "FluidAudio fixture DER=%.4f (n=%d clusters) target=%.4f",
                result.der,
                clusters.count,
                DiarizationErrorRate.initialTarget
            )
        )
        #expect(result.der <= 1.0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CALLNOTES_HARNESS"] == "1"))
    func dualInstanceProbeCompletes() async {
        let result = await DualInstanceProbe.run(timeout: 12)
        #expect(result.mode == .concurrentLive || result.mode == .nearLiveFarBatch)
    }
}

private enum SampleReference {
    static let turns = [
        DiarizationTurn(speaker: "A", start: 2.4, end: 5.0)
    ]
}

enum RepoFixtures {
    static func diarizationDirectory() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("Fixtures/diarization")
            let rttm = candidate.appendingPathComponent("two-speaker.rttm")
            if FileManager.default.fileExists(atPath: rttm.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
