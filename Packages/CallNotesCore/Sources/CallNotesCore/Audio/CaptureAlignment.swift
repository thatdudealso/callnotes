import Foundation

public enum CaptureAlignment: Sendable {
    public struct Result: Equatable, Sendable {
        public var lagSeconds: TimeInterval
        public var nearSilent: Bool
        public var farSilent: Bool
        public var hasStartTimestamps: Bool

        public var isAligned: Bool {
            hasStartTimestamps && abs(lagSeconds) <= AudioConstants.alignmentTolerance
        }

        public var bothChannelsLive: Bool {
            !nearSilent && !farSilent
        }
    }

    public static func analyze(
        near: [Int16],
        far: [Int16],
        nearStartTime: TimeInterval?,
        farStartTime: TimeInterval?,
        rmsThreshold: Float = AudioConstants.silenceRMSThreshold
    ) -> Result {
        let frames = min(near.count, far.count)
        let nearSlice = Array(near.prefix(frames))
        let farSlice = Array(far.prefix(frames))
        let hasStartTimestamps = nearStartTime != nil && farStartTime != nil
        let lagSeconds: TimeInterval
        if let nearStartTime, let farStartTime {
            lagSeconds = farStartTime - nearStartTime
        } else {
            lagSeconds = .infinity
        }
        return Result(
            lagSeconds: lagSeconds,
            nearSilent: isSilent(nearSlice, rmsThreshold: rmsThreshold),
            farSilent: isSilent(farSlice, rmsThreshold: rmsThreshold),
            hasStartTimestamps: hasStartTimestamps
        )
    }

    public static func isSilent(_ samples: [Int16], rmsThreshold: Float = AudioConstants.silenceRMSThreshold) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for sample in samples {
            let v = Float(sample)
            sum += v * v
        }
        let rms = sqrt(sum / Float(samples.count))
        return rms < rmsThreshold
    }

}
