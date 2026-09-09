import Foundation

public enum CaptureAlignment: Sendable {
    /// Converts tap render timestamps and mic node timestamps onto a shared
    /// presentation timeline using measured device I/O latency. Never a
    /// hardcoded fudge; pass the values Core Audio / AVAudioEngine report.
    public struct LatencyCompensation: Equatable, Sendable {
        public var farRenderToPresentationSeconds: TimeInterval
        public var nearNodeToCapsuleSeconds: TimeInterval

        public static let none = LatencyCompensation(
            farRenderToPresentationSeconds: 0,
            nearNodeToCapsuleSeconds: 0
        )

        public init(
            farRenderToPresentationSeconds: TimeInterval = 0,
            nearNodeToCapsuleSeconds: TimeInterval = 0
        ) {
            self.farRenderToPresentationSeconds = farRenderToPresentationSeconds
            self.nearNodeToCapsuleSeconds = nearNodeToCapsuleSeconds
        }

        public func presentedFarStart(_ farStart: TimeInterval) -> TimeInterval {
            farStart + farRenderToPresentationSeconds
        }

        public func capsuleNearStart(_ nearStart: TimeInterval) -> TimeInterval {
            nearStart - nearNodeToCapsuleSeconds
        }

        public func lagSeconds(farStart: TimeInterval, nearStart: TimeInterval) -> TimeInterval {
            presentedFarStart(farStart) - capsuleNearStart(nearStart)
        }

        public func sampleShift(farStart: TimeInterval, nearStart: TimeInterval, sampleRate: Double) -> Int {
            Int((lagSeconds(farStart: farStart, nearStart: nearStart) * sampleRate).rounded())
        }
    }

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

    /// Positive shift: far is presented later, pad `shift` frames onto far.
    /// Negative shift: far was presented earlier (tap started first). Trim
    /// that lead from far so both channels start when both are live, instead
    /// of padding silence onto near. That keeps capture-host timestamps
    /// comparable without a hardcoded fudge.
    public static func leadingAdjustments(shift: Int) -> (nearPad: Int, farPad: Int, farTrim: Int) {
        if shift > 0 { return (0, shift, 0) }
        if shift < 0 { return (0, 0, -shift) }
        return (0, 0, 0)
    }

    public static func analyze(
        near: [Int16],
        far: [Int16],
        nearStartTime: TimeInterval?,
        farStartTime: TimeInterval?,
        rmsThreshold: Float = AudioConstants.silenceRMSThreshold,
        latency: LatencyCompensation = .none
    ) -> Result {
        let frames = min(near.count, far.count)
        let nearSlice = Array(near.prefix(frames))
        let farSlice = Array(far.prefix(frames))
        let hasStartTimestamps = nearStartTime != nil && farStartTime != nil
        let lagSeconds: TimeInterval
        if let nearStartTime, let farStartTime {
            lagSeconds = latency.lagSeconds(farStart: farStartTime, nearStart: nearStartTime)
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
