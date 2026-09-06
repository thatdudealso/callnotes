import Foundation

/// Linear resampler plus Int16 conversion used by the capture graph.
/// Linear interpolation is deterministic (unit-testable without live audio)
/// and good enough for the 16 kHz local-engine branch.
public enum PCMResampler: Sendable {
    public static func resampleMono(
        input: [Float],
        inputSampleRate: Double,
        outputSampleRate: Double = Double(AudioConstants.localSampleRate)
    ) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard inputSampleRate > 0, outputSampleRate > 0 else { return [] }
        if inputSampleRate == outputSampleRate {
            return input
        }
        let ratio = inputSampleRate / outputSampleRate
        let outputCount = max(1, Int((Double(input.count) / ratio).rounded(.down)))
        var output = [Float](repeating: 0, count: outputCount)
        let last = input.count - 1
        for i in 0..<outputCount {
            let src = Double(i) * ratio
            let idx = Int(src)
            let frac = Float(src - Double(idx))
            if idx >= last {
                output[i] = input[last]
            } else {
                output[i] = input[idx] * (1 - frac) + input[idx + 1] * frac
            }
        }
        return output
    }

    public static func floatToInt16(_ input: [Float]) -> [Int16] {
        input.map(clipToInt16)
    }

    public static func int16ToFloat(_ input: [Int16]) -> [Float] {
        let scale = 1 / Float(Int16.max)
        return input.map { Float($0) * scale }
    }

    public static func resampleMonoToInt16(
        input: [Float],
        inputSampleRate: Double,
        outputSampleRate: Double = Double(AudioConstants.localSampleRate)
    ) -> [Int16] {
        floatToInt16(resampleMono(input: input, inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate))
    }

    /// Mix a stereo (or multi-channel interleaved) float buffer down to mono.
    public static func mixdownMono(interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        if channels == 1 { return interleaved }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        let inv = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for ch in 0..<channels {
                sum += interleaved[base + ch]
            }
            mono[frame] = sum * inv
        }
        return mono
    }

    public static func clipToInt16(_ sample: Float) -> Int16 {
        let clipped = max(-1, min(1, sample))
        return Int16((clipped * Float(Int16.max)).rounded())
    }
}