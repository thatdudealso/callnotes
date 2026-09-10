import AVFoundation
import Foundation

public enum StereoCAFWriterError: Error, Equatable, Sendable {
    case invalidFormat
    case channelLengthMismatch
    case closed
}

/// Incrementally writes a 2-channel CAF: L = near, R = far, 16 kHz Int16.
public final class StereoCAFWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public private(set) var framesWritten: Int = 0

    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat

    public init(
        url: URL,
        sampleRate: Double = Double(AudioConstants.localSampleRate)
    ) throws {
        self.url = url
        self.sampleRate = sampleRate
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(AudioConstants.captureChannels),
            interleaved: true
        ) else {
            throw StereoCAFWriterError.invalidFormat
        }
        self.processingFormat = processingFormat
        var settings = processingFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    public func write(near: [Int16], far: [Int16]) throws {
        let frames = min(near.count, far.count)
        guard near.count == far.count else {
            throw StereoCAFWriterError.channelLengthMismatch
        }
        guard frames > 0 else { return }
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[i * 2 + AudioConstants.nearChannelIndex] = near[i]
            interleaved[i * 2 + AudioConstants.farChannelIndex] = far[i]
        }
        try writeInterleaved(interleaved)
    }

    public func writeInterleaved(_ interleaved: [Int16]) throws {
        let channels = AudioConstants.captureChannels
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw StereoCAFWriterError.invalidFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let dest = buffer.int16ChannelData else {
            throw StereoCAFWriterError.invalidFormat
        }
        guard let file else { throw StereoCAFWriterError.closed }
        interleaved.withUnsafeBufferPointer { src in
            dest[0].update(from: src.baseAddress!, count: frames * channels)
        }
        try file.write(from: buffer)
        framesWritten += frames
    }

    /// Releases the AVAudioFile (which flushes the CAF header) and stamps the
    /// near/far marker, so a later import can prove this file's channel layout.
    public func close() {
        guard file != nil else { return }
        file = nil
        try? CaptureChannelMarker.stampNearFar(url)
    }
}

/// Reads a capture CAF back as separate near/far Int16 channels.
public enum StereoCAFReader: Sendable {
    public struct Channels: Sendable {
        public var near: [Int16]
        public var far: [Int16]
        public var sampleRate: Double
        public var fileType: AudioFileTypeID
    }

    public static func read(_ url: URL) throws -> Channels {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw StereoCAFWriterError.invalidFormat
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        var near = [Int16](repeating: 0, count: frames)
        var far = [Int16](repeating: 0, count: frames)

        if format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData {
            if format.isInterleaved {
                let src = channels[0]
                for i in 0..<frames {
                    near[i] = src[i * 2]
                    far[i] = src[i * 2 + 1]
                }
            } else {
                let left = channels[0]
                let right = format.channelCount > 1 ? channels[1] : channels[0]
                for i in 0..<frames {
                    near[i] = left[i]
                    far[i] = right[i]
                }
            }
        } else if let channels = buffer.floatChannelData {
            if format.isInterleaved {
                let src = channels[0]
                for i in 0..<frames {
                    near[i] = PCMResampler.clipToInt16(src[i * 2])
                    far[i] = PCMResampler.clipToInt16(src[i * 2 + 1])
                }
            } else {
                let left = channels[0]
                let right = format.channelCount > 1 ? channels[1] : channels[0]
                for i in 0..<frames {
                    near[i] = PCMResampler.clipToInt16(left[i])
                    far[i] = PCMResampler.clipToInt16(right[i])
                }
            }
        }

        return Channels(
            near: near,
            far: far,
            sampleRate: file.fileFormat.sampleRate,
            fileType: file.fileFormat.settings[AVFormatIDKey] as? AudioFileTypeID ?? 0
        )
    }
}