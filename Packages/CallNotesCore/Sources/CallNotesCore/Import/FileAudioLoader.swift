@preconcurrency import AVFoundation
import Foundation

/// Decodes an imported audio file (m4a, CAF, WAV, AIFF) into 16 kHz Int16 PCM.
/// Stereo files keep L = near, R = far; mono files put everything on `near`.
public enum FileAudioLoader {
    public struct LoadedAudio: Sendable {
        public var near: Data
        public var far: Data
        public var sampleRate: Int
        public var duration: TimeInterval
        public var channelCount: Int

        public init(near: Data, far: Data, sampleRate: Int, duration: TimeInterval, channelCount: Int) {
            self.near = near
            self.far = far
            self.sampleRate = sampleRate
            self.duration = duration
            self.channelCount = channelCount
        }

        public var isStereo: Bool { channelCount >= 2 && !far.isEmpty }
        public var mixed: Data { isStereo ? mix(near, far) : near }
    }

    public static func load(
        _ url: URL,
        targetSampleRate: Int = AudioConstants.localSampleRate
    ) throws -> LoadedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw FileImportError.invalidAudio("CallNotes could not decode this audio file")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else {
            throw FileImportError.invalidAudio("The imported audio file is empty")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw FileImportError.invalidAudio("CallNotes could not allocate an import audio buffer")
        }
        try file.read(into: buffer)
        buffer.frameLength = frames

        let channelCount = Int(file.processingFormat.channelCount)
        var near = try int16Channel(buffer, channel: 0)
        var far = channelCount >= 2 ? try int16Channel(buffer, channel: 1) : Data()
        let sourceRate = file.processingFormat.sampleRate
        if Int(sourceRate.rounded()) != targetSampleRate {
            near = resample(near, from: sourceRate, to: Double(targetSampleRate))
            if !far.isEmpty {
                far = resample(far, from: sourceRate, to: Double(targetSampleRate))
            }
        }
        let frameCount = near.count / MemoryLayout<Int16>.size
        let duration = Double(frameCount) / Double(targetSampleRate)
        return LoadedAudio(
            near: near,
            far: far,
            sampleRate: targetSampleRate,
            duration: duration,
            channelCount: channelCount
        )
    }

    private static func int16Channel(_ buffer: AVAudioPCMBuffer, channel: Int) throws -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        let channelCount = Int(buffer.format.channelCount)
        guard channel >= 0, channel < channelCount else { return Data() }
        var samples = [Int16](repeating: 0, count: frames)
        if buffer.format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let source = UnsafeBufferPointer(start: channels[0], count: frames * channelCount)
                for index in 0..<frames {
                    samples[index] = source[index * channelCount + channel]
                }
            } else {
                let source = UnsafeBufferPointer(start: channels[channel], count: frames)
                for index in 0..<frames {
                    samples[index] = source[index]
                }
            }
        } else if buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let source = UnsafeBufferPointer(start: channels[0], count: frames * channelCount)
                for index in 0..<frames {
                    samples[index] = clipToInt16(source[index * channelCount + channel])
                }
            } else {
                let source = UnsafeBufferPointer(start: channels[channel], count: frames)
                for index in 0..<frames {
                    samples[index] = clipToInt16(source[index])
                }
            }
        } else {
            throw FileImportError.invalidAudio("CallNotes could not read this audio file's sample format")
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func resample(_ pcm: Data, from inputRate: Double, to outputRate: Double) -> Data {
        let samples = pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        let floats = PCMResampler.int16ToFloat(samples)
        let resampled = PCMResampler.resampleMono(input: floats, inputSampleRate: inputRate, outputSampleRate: outputRate)
        return PCMResampler.floatToInt16(resampled).withUnsafeBytes { Data($0) }
    }

    private static func clipToInt16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = max(-1 as Float, min(1 as Float, value))
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private static func mix(_ near: Data, _ far: Data) -> Data {
        let nearSamples = near.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let farSamples = far.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let count = max(nearSamples.count, farSamples.count)
        var mixed = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let left = index < nearSamples.count ? Int32(nearSamples[index]) : 0
            let right = index < farSamples.count ? Int32(farSamples[index]) : 0
            let sum = (left + right) / 2
            mixed[index] = Int16(clamping: sum)
        }
        return mixed.withUnsafeBytes { Data($0) }
    }
}
