import AudioToolbox
import AVFoundation
import Foundation

public enum StereoCAFWriterError: Error, Equatable, Sendable {
    case invalidFormat
    case channelLengthMismatch
    case closed
}

/// Incrementally writes a 2-channel CAF: L = near, R = far, 16 kHz Int16.
/// Packet count is persisted after every write so a SIGKILL still leaves a
/// file `CAFHeaderRepair` and `AVAudioFile` can open.
public final class StereoCAFWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public private(set) var framesWritten: Int = 0

    private var fileID: AudioFileID?
    private var asbd: AudioStreamBasicDescription

    public init(
        url: URL,
        sampleRate: Double = Double(AudioConstants.localSampleRate)
    ) throws {
        self.url = url
        self.sampleRate = sampleRate
        let bytesPerFrame = UInt32(AudioConstants.captureChannels * MemoryLayout<Int16>.size)
        self.asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(AudioConstants.captureChannels),
            mBitsPerChannel: UInt32(AudioConstants.captureBitDepth),
            mReserved: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var file: AudioFileID?
        var format = asbd
        let status = AudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &format,
            .eraseFile,
            &file
        )
        guard status == noErr, let file else {
            throw StereoCAFWriterError.invalidFormat
        }
        self.fileID = file
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
        guard let fileID else { throw StereoCAFWriterError.closed }
        var packetCount = UInt32(frames)
        let byteCount = UInt32(interleaved.count * MemoryLayout<Int16>.size)
        let start = Int64(framesWritten)
        let status = interleaved.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioFileUnspecifiedError }
            return AudioFileWritePackets(
                fileID,
                false,
                byteCount,
                nil,
                start,
                &packetCount,
                base
            )
        }
        guard status == noErr else { throw StereoCAFWriterError.invalidFormat }
        framesWritten += Int(packetCount)
        try persistPacketCount()
    }

    /// Flushes the CAF `data` chunk size to disk. Called after every write so
    /// a mid-call kill still leaves a processable file.
    public func persistPacketCount() throws {
        guard let fileID else { return }
        var count = Int64(framesWritten)
        let status = AudioFileSetProperty(
            fileID,
            kAudioFilePropertyAudioDataPacketCount,
            UInt32(MemoryLayout<Int64>.size),
            &count
        )
        guard status == noErr else { throw StereoCAFWriterError.invalidFormat }
        try FileHandle(forWritingTo: url).synchronize()
    }

    /// Releases the AudioFile (which finalizes the CAF header) and stamps the
    /// near/far marker, so a later import can prove this file's channel layout.
    public func close() {
        guard let fileID else { return }
        AudioFileClose(fileID)
        self.fileID = nil
        try? CaptureChannelMarker.stampNearFar(url)
    }

    /// Drops the file handle without `AudioFileClose`, matching a SIGKILL.
    public func abandonWithoutClosing() {
        fileID = nil
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