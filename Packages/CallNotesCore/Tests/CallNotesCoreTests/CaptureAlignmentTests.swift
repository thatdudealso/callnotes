import Foundation
import Testing

@testable import CallNotesCore

@Suite struct CaptureAlignmentTests {
    @Test func startTimesWithinToleranceAreAligned() {
        let result = CaptureAlignment.analyze(
            near: makePulse(frames: 2_000, pulseAt: 200),
            far: makePulse(frames: 2_000, pulseAt: 800),
            nearStartTime: 10,
            farStartTime: 10.049
        )
        #expect(abs(result.lagSeconds - 0.049) < 0.001)
        #expect(result.isAligned)
        #expect(result.bothChannelsLive)
    }

    @Test func startTimesBeyondToleranceFailAlignment() {
        let result = CaptureAlignment.analyze(
            near: makePulse(frames: 8_000, pulseAt: 400),
            far: makePulse(frames: 8_000, pulseAt: 1_600),
            nearStartTime: 10,
            farStartTime: 10.051
        )
        #expect(abs(result.lagSeconds - 0.051) < 0.001)
        #expect(!result.isAligned)
    }

    @Test func missingStartTimeFailsAlignment() {
        let result = CaptureAlignment.analyze(
            near: makePulse(frames: 1_000, pulseAt: 10),
            far: makePulse(frames: 1_000, pulseAt: 700),
            nearStartTime: 10,
            farStartTime: nil
        )
        #expect(!result.hasStartTimestamps)
        #expect(!result.isAligned)
    }

    @Test func silentChannelIsDetected() {
        #expect(CaptureAlignment.isSilent([Int16](repeating: 0, count: 1_000)))
        #expect(!CaptureAlignment.isSilent(makePulse(frames: 1_000, pulseAt: 10)))
    }

    @Test func speakerToMicCouplingRMSIsNotSilent() {
        // Built-in speaker-to-mic coupling of the harness tone is ~150 Int16 RMS.
        #expect(!CaptureAlignment.isSilent([Int16](repeating: 150, count: 1_000)))
        #expect(CaptureAlignment.isSilent([Int16](repeating: 40, count: 1_000)))
    }

    @Test func hardwareLatencyCompensationAlignsRenderTimeFarWithCapsuleNear() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.013,
            nearNodeToCapsuleSeconds: 0.011
        )
        #expect(abs(compensation.lagSeconds(farStart: 10.000, nearStart: 10.024)) < 0.000_5)
        let result = CaptureAlignment.analyze(
            near: makePulse(frames: 2_000, pulseAt: 200),
            far: makePulse(frames: 2_000, pulseAt: 200),
            nearStartTime: 10.024,
            farStartTime: 10.000,
            latency: compensation
        )
        #expect(abs(result.lagSeconds) < 0.000_5)
        #expect(result.isAligned)
    }

    @Test func smallHardwareLatencyDoesNotHideAHundredMillisecondStartSkew() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.013,
            nearNodeToCapsuleSeconds: 0.012
        )
        let lag = compensation.lagSeconds(farStart: 10.000, nearStart: 10.127)
        #expect(abs(lag - (-0.102)) < 0.000_5)
        let result = CaptureAlignment.analyze(
            near: makePulse(frames: 2_000, pulseAt: 200),
            far: makePulse(frames: 2_000, pulseAt: 200),
            nearStartTime: 10.127,
            farStartTime: 10.000,
            latency: compensation
        )
        #expect(!result.isAligned)
    }

    @Test func sampleShiftIsZeroWhenPresentedStartsMatch() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.010,
            nearNodeToCapsuleSeconds: 0.010
        )
        #expect(compensation.sampleShift(farStart: 1.000, nearStart: 1.020, sampleRate: 16_000) == 0)
        let pads = CaptureAlignment.leadingAdjustments(shift: 0)
        #expect(pads.nearPad == 0)
        #expect(pads.farPad == 0)
        #expect(pads.farTrim == 0)
    }

    @Test func sampleShiftTrimsFarWhenFarIsPresentedEarlier() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.012,
            nearNodeToCapsuleSeconds: 0.004
        )
        // presented far = 1.012, capsule near = 1.020, lag = -0.008 s → -128 samples at 16 kHz
        let shift = compensation.sampleShift(farStart: 1.000, nearStart: 1.024, sampleRate: 16_000)
        #expect(shift == -128)
        let pads = CaptureAlignment.leadingAdjustments(shift: shift)
        #expect(pads.nearPad == 0)
        #expect(pads.farPad == 0)
        #expect(pads.farTrim == 128)
    }

    @Test func sampleShiftPadsFarWhenFarIsPresentedLater() {
        let shift = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.020,
            nearNodeToCapsuleSeconds: 0
        ).sampleShift(farStart: 1.010, nearStart: 1.000, sampleRate: 16_000)
        // presented far = 1.030, capsule near = 1.000, lag = +0.030 s → 480 samples
        #expect(shift == 480)
        let pads = CaptureAlignment.leadingAdjustments(shift: shift)
        #expect(pads.nearPad == 0)
        #expect(pads.farPad == 480)
        #expect(pads.farTrim == 0)
    }

    @Test func advancingFarStartByNegativeLagCancelsCompensatedLag() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.013,
            nearNodeToCapsuleSeconds: 0.012
        )
        let farStart = 10.000
        let nearStart = 10.127
        let lag = compensation.lagSeconds(farStart: farStart, nearStart: nearStart)
        let rebasedFar = farStart - lag
        #expect(abs(compensation.lagSeconds(farStart: rebasedFar, nearStart: nearStart)) < 0.000_5)
    }

    @Test func delayingFarStartByPositivePadCancelsCompensatedLag() {
        let compensation = CaptureAlignment.LatencyCompensation(
            farRenderToPresentationSeconds: 0.020,
            nearNodeToCapsuleSeconds: 0
        )
        let farStart = 1.010
        let nearStart = 1.000
        let sampleRate = 16_000.0
        let shift = compensation.sampleShift(farStart: farStart, nearStart: nearStart, sampleRate: sampleRate)
        #expect(shift > 0)
        let pads = CaptureAlignment.leadingAdjustments(shift: shift)
        #expect(pads.farPad == shift)
        let rebasedFar = farStart - Double(pads.farPad) / sampleRate
        #expect(abs(compensation.lagSeconds(farStart: rebasedFar, nearStart: nearStart)) < 0.000_5)
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
