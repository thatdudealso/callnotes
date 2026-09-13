import Foundation

/// PCM for the Mac consent injection (plan section 13). The tone option is a
/// short 440 Hz lead-in plus a 1 kHz carrier the far-side mic can pick up;
/// spoken-line synthesis is layered by the Mac injector when voices exist.
public enum ConsentAnnouncement: Sendable {
    public static let toneSampleRate = AudioConstants.localSampleRate
    /// 250 ms of 440 Hz, then 750 ms of 1 kHz, at a level that survives AEC.
    public static let durationSeconds: Double = 1.0

    public static func tonePCM(sampleRate: Int = toneSampleRate) -> [Int16] {
        let total = Int(Double(sampleRate) * durationSeconds)
        let beepFrames = sampleRate / 4
        var samples = [Int16](repeating: 0, count: total)
        let amplitude = Int16(12_000)
        for i in 0..<total {
            let frequency: Double = i < beepFrames ? 440 : 1_000
            let phase = 2.0 * Double.pi * frequency * Double(i) / Double(sampleRate)
            samples[i] = Int16((Double(amplitude) * sin(phase)).rounded())
        }
        return samples
    }

    public static func injection(for policy: ConsentPolicy) -> [Int16]? {
        guard policy.injectsAnnouncement else { return nil }
        return tonePCM()
    }

    /// Mixes remaining injection samples into a near-channel capture buffer.
    public static func mix(_ tone: [Int16], into samples: inout [Int16], consumed: inout Int) {
        guard consumed < tone.count, !samples.isEmpty else { return }
        let count = min(samples.count, tone.count - consumed)
        for index in 0..<count {
            let mixed = Int32(samples[index]) + Int32(tone[consumed + index])
            samples[index] = Int16(clamping: mixed)
        }
        consumed += count
    }
}
