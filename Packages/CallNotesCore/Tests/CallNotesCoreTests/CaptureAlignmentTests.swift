import Foundation
import Testing

@testable import CallNotesCore

@Suite struct CaptureAlignmentTests {
    @Test func identicalSignalsHaveZeroLagAndAreLive() {
        let pulse = makePulse(frames: 2_000, pulseAt: 200)
        let result = CaptureAlignment.analyze(near: pulse, far: pulse, sampleRate: 16_000)
        #expect(abs(result.lagSeconds) < 0.001)
        #expect(result.isAligned)
        #expect(result.bothChannelsLive)
    }

    @Test func tenMillisecondFarDelayIsWithinTolerance() {
        let near = makePulse(frames: 4_000, pulseAt: 400)
        let delay = 160 // 10 ms at 16 kHz
        var far = [Int16](repeating: 0, count: near.count)
        for i in delay..<near.count {
            far[i] = near[i - delay]
        }
        let result = CaptureAlignment.analyze(near: near, far: far, sampleRate: 16_000)
        #expect(abs(result.lagSeconds - 0.010) < 0.002)
        #expect(result.isAligned)
    }

    @Test func eightyMillisecondDelayFailsAlignment() {
        let near = makePulse(frames: 8_000, pulseAt: 400)
        let delay = 1_280 // 80 ms at 16 kHz
        var far = [Int16](repeating: 0, count: near.count)
        for i in delay..<near.count {
            far[i] = near[i - delay]
        }
        let result = CaptureAlignment.analyze(near: near, far: far, sampleRate: 16_000)
        #expect(abs(result.lagSeconds - 0.080) < 0.005)
        #expect(!result.isAligned)
    }

    @Test func silentChannelIsDetected() {
        #expect(CaptureAlignment.isSilent([Int16](repeating: 0, count: 1_000)))
        #expect(!CaptureAlignment.isSilent(makePulse(frames: 1_000, pulseAt: 10)))
    }

    @Test func callAppNameMatcherObservesDisplayNamesNotBundleIDs() {
        #expect(CallAppNameMatcher.isCallAppDisplayName("FaceTime"))
        #expect(CallAppNameMatcher.isCallAppDisplayName("Phone"))
        #expect(CallAppNameMatcher.isCallAppDisplayName("phone"))
        #expect(!CallAppNameMatcher.isCallAppDisplayName("Safari"))
        #expect(CallAppNameMatcher.isCallLink("Join via facetime://example"))
        #expect(CallAppNameMatcher.isCallLink("tel:+15551212"))
        #expect(!CallAppNameMatcher.isCallLink("Weekly planning in the office"))
    }

    private func makePulse(frames: Int, pulseAt: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<80 {
            let idx = pulseAt + i
            if idx < frames {
                samples[idx] = 20_000
            }
        }
        return samples
    }
}