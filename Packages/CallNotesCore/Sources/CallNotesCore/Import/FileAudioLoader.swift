@preconcurrency import AVFoundation
import Foundation

/// Decodes an imported audio file (m4a, CAF, WAV, AIFF) into 16 kHz Int16 PCM.
/// Stereo files keep L = near, R = far; mono files put everything on `near`.
public enum FileAudioLoader {
    /// Only CallNotes' own capture CAF carries L = near (owner) and R = far.
    /// Any other two-channel file is room audio on both channels, so it is
    /// downmixed and diarized instead of being split by channel.
    public enum ChannelLayout: String, Sendable, Equatable {
        case mono
        case captureNearFar
        case unknownStereo
    }

    public struct LoadedAudio: Sendable {
        public var near: Data
        public var far: Data
        public var sampleRate: Int
        public var duration: TimeInterval
        public var channelCount: Int
        public var layout: ChannelLayout

        public init(
            near: Data,
            far: Data,
            sampleRate: Int,
            duration: TimeInterval,
            channelCount: Int,
            layout: ChannelLayout = .mono
        ) {
            self.near = near
            self.far = far
            self.sampleRate = sampleRate
            self.duration = duration
            self.channelCount = channelCount
            self.layout = layout
        }

        public var isStereo: Bool { layout == .captureNearFar && !far.isEmpty }
        public var mixed: Data { far.isEmpty ? near : mix(near, far) }
    }

    public static func channelLayout(for url: URL, channelCount: Int) -> ChannelLayout {
        guard channelCount >= 2 else { return .mono }
        guard channelCount == 2, CaptureChannelMarker.hasNearFarMarker(url) else { return .unknownStereo }
        return .captureNearFar
    }

    /// Decoded in bounded batches so peak memory does not scale with the
    /// recording length; the resampler carries its phase across batches.
    static let decodeBatchSeconds: Double = 30

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
        guard file.length > 0 else {
            throw FileImportError.invalidAudio("The imported audio file is empty")
        }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw FileImportError.invalidAudio("CallNotes could not read this audio file's sample format")
        }
        let channelCount = Int(format.channelCount)
        let layout = channelLayout(for: url, channelCount: channelCount)
        let sourceRate = format.sampleRate
        let batchFrames = AVAudioFrameCount(max(1, Int(decodeBatchSeconds * sourceRate)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: batchFrames) else {
            throw FileImportError.invalidAudio("CallNotes could not allocate an import audio buffer")
        }

        var nearResampler = StreamingPCMResampler(
            inputSampleRate: sourceRate,
            outputSampleRate: Double(targetSampleRate)
        )
        var farResampler = nearResampler
        var near = Data()
        var far = Data()
        let expectedBytes = Int(Double(file.length) * Double(targetSampleRate) / sourceRate) * 2
        near.reserveCapacity(expectedBytes)
        if layout == .captureNearFar { far.reserveCapacity(expectedBytes) }

        var decodedFrames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            decodedFrames += frames
            guard let channels = buffer.floatChannelData else {
                throw FileImportError.invalidAudio("CallNotes could not read this audio file's sample format")
            }
            if layout == .captureNearFar {
                near.append(int16Data(resampler: &nearResampler, batch: samples(channels[0], frames: frames)))
                far.append(int16Data(resampler: &farResampler, batch: samples(channels[1], frames: frames)))
            } else {
                near.append(
                    int16Data(
                        resampler: &nearResampler,
                        batch: downmix(channels, channelCount: channelCount, frames: frames)
                    )
                )
            }
        }
        guard decodedFrames > 0 else {
            throw FileImportError.invalidAudio("CallNotes could not decode any audio from this file")
        }

        let frameCount = near.count / MemoryLayout<Int16>.size
        let duration = Double(frameCount) / Double(targetSampleRate)
        return LoadedAudio(
            near: near,
            far: far,
            sampleRate: targetSampleRate,
            duration: duration,
            channelCount: channelCount,
            layout: layout
        )
    }

    private static func samples(_ source: UnsafeMutablePointer<Float>, frames: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: source, count: frames))
    }

    /// Everything that is not CallNotes' own near/far capture is room audio, so
    /// every channel is averaged into one stream: a 5.1 interview keeps its
    /// centre-channel speech instead of importing a silent L/R pair.
    private static func downmix(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frames: Int
    ) -> [Float] {
        var batch = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(max(channelCount, 1))
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<frames {
                batch[index] += source[index] * scale
            }
        }
        return batch
    }

    private static func int16Data(
        resampler: inout StreamingPCMResampler,
        batch: [Float]
    ) -> Data {
        let resampled = resampler.resampleMono(batch)
        var samples = [Int16](repeating: 0, count: resampled.count)
        for index in 0..<resampled.count {
            samples[index] = clipToInt16(resampled[index])
        }
        return samples.withUnsafeBytes { Data($0) }
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
