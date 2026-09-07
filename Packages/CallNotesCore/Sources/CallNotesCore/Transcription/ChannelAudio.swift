import AVFoundation
import Foundation

/// Splits and writes the 2-channel capture CAF (L = near, R = far).
public enum ChannelAudio {
    public struct Split: Sendable {
        public var near: Data
        public var far: Data
        public var sampleRate: Double
        public var frameCount: AVAudioFrameCount
    }

    public static func splitStereoCAF(url: URL) throws -> Split {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else {
            return Split(near: Data(), far: Data(), sampleRate: format.sampleRate, frameCount: 0)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SpeechAnalyzerServiceError.audioBufferCreationFailed
        }
        try file.read(into: buffer)
        buffer.frameLength = frames

        if format.channelCount == 1 {
            let pcm = int16Data(from: buffer, channel: 0)
            return Split(near: pcm, far: Data(), sampleRate: format.sampleRate, frameCount: frames)
        }

        return Split(
            near: int16Data(from: buffer, channel: 0),
            far: int16Data(from: buffer, channel: 1),
            sampleRate: format.sampleRate,
            frameCount: frames
        )
    }

    public static func writeMonoCAF(
        pcm16: Data,
        sampleRate: Double = Double(AudioConstants.localSampleRate),
        to url: URL
    ) throws {
        try writeCAF(channels: [pcm16], sampleRate: sampleRate, to: url)
    }

    public static func writeStereoCAF(
        near: Data,
        far: Data,
        sampleRate: Double = Double(AudioConstants.localSampleRate),
        to url: URL
    ) throws {
        try writeCAF(channels: [near, far], sampleRate: sampleRate, to: url)
    }

    /// Fill a non-interleaved Float32 buffer. AVAudioFile may coerce the on-disk
    /// CAF to interleaved; filling an interleaved buffer here fails with -50.
    private static func writeCAF(channels: [Data], sampleRate: Double, to url: URL) throws {
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        let frameCount = channels.map { $0.count / MemoryLayout<Int16>.size }.max() ?? 0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw SpeechAnalyzerServiceError.noCompatibleAudioFormat
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(frameCount, 1))
        ) else {
            throw SpeechAnalyzerServiceError.audioBufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let dest = buffer.floatChannelData else {
            throw SpeechAnalyzerServiceError.audioBufferCreationFailed
        }
        for channel in 0..<Int(channelCount) {
            let pcm = channel < channels.count ? channels[channel] : Data()
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<frameCount {
                    let value = index < samples.count ? Float(samples[index]) / Float(Int16.max) : 0
                    dest[channel][index] = value
                }
            }
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        if frameCount > 0 {
            try file.write(from: buffer)
        }
    }

    private static func int16Data(from buffer: AVAudioPCMBuffer, channel: Int) -> Data {
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
            return samples.withUnsafeBytes { Data($0) }
        }
        if buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let source = UnsafeBufferPointer(start: channels[0], count: frames * channelCount)
                for index in 0..<frames {
                    samples[index] = int16(from: source[index * channelCount + channel])
                }
            } else {
                let source = UnsafeBufferPointer(start: channels[channel], count: frames)
                for index in 0..<frames {
                    samples[index] = int16(from: source[index])
                }
            }
            return samples.withUnsafeBytes { Data($0) }
        }
        return Data()
    }

    private static func int16(from value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = max(-1 as Float, min(1 as Float, value))
        return Int16((clamped * Float(Int16.max)).rounded())
    }
}
