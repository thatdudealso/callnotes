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
