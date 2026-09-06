import Foundation

/// Cross-correlation alignment and silence checks used by the capture harness.
public enum CaptureAlignment: Sendable {
    public struct Result: Equatable, Sendable {
        public var lagSeconds: TimeInterval
        public var peakCorrelation: Double
        public var nearSilent: Bool
        public var farSilent: Bool

        public var isAligned: Bool {
            abs(lagSeconds) <= AudioConstants.alignmentTolerance
        }

        public var bothChannelsLive: Bool {
            !nearSilent && !farSilent
        }
    }

    public static func analyze(
        near: [Int16],
        far: [Int16],
        sampleRate: Double = Double(AudioConstants.localSampleRate),
        rmsThreshold: Float = AudioConstants.silenceRMSThreshold
    ) -> Result {
        let frames = min(near.count, far.count)
        let nearSlice = Array(near.prefix(frames))
        let farSlice = Array(far.prefix(frames))
        let (lagFrames, peak) = lag(near: nearSlice, far: farSlice, sampleRate: sampleRate)
        let lagSeconds = sampleRate > 0 ? Double(lagFrames) / sampleRate : 0
        return Result(
            lagSeconds: lagSeconds,
            peakCorrelation: peak,
            nearSilent: isSilent(nearSlice, rmsThreshold: rmsThreshold),
            farSilent: isSilent(farSlice, rmsThreshold: rmsThreshold)
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

    /// Positive lag means `far` is delayed relative to `near`.
    public static func lag(
        near: [Int16],
        far: [Int16],
        sampleRate: Double
    ) -> (frames: Int, peak: Double) {
        let frames = min(near.count, far.count)
        guard frames > 1, sampleRate > 0 else { return (0, 0) }
        let maxLag = min(frames / 2, max(1, Int((0.1 * sampleRate).rounded())))
        var bestLag = 0
        var bestScore = -Double.infinity
        for lagFrames in -maxLag...maxLag {
            var acc: Double = 0
            var count = 0
            for i in 0..<frames {
                let j = i + lagFrames
                if j < 0 || j >= frames { continue }
                acc += Double(near[i]) * Double(far[j])
                count += 1
            }
            let score = count > 0 ? acc / Double(count) : 0
            if score > bestScore {
                bestScore = score
                bestLag = lagFrames
            }
        }
        return (bestLag, bestScore)
    }
}