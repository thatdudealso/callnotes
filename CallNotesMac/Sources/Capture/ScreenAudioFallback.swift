import AVFoundation
import CallNotesCore
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// Last-resort far-channel capture: ScreenCaptureKit audio-only stream.
final class ScreenAudioFallback: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    struct Sample: Sendable {
        var mono: [Float]
        var sampleRate: Double
        var hostTime: UInt64
    }

    var onSamples: (@Sendable (Sample) -> Void)?

    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "ScreenAudio")
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.thatdudealso.callnotes.sck-audio")
    private(set) var isRunning = false

    func start() async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.screenCaptureFallbackFailed("No display available for audio capture")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
        logger.info("ScreenCaptureKit audio fallback started")
    }

    func stop() async {
        guard let stream else {
            isRunning = false
            return
        }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        guard let block = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer
        else { return }

        let channels = Int(max(1, format.mChannelsPerFrame))
        let frameCount: Int
        let mono: [Float]
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            frameCount = length / (MemoryLayout<Float>.size * channels)
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: frameCount * channels)
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for i in 0..<(frameCount * channels) {
                interleaved[i] = samples[i]
            }
            mono = PCMResampler.mixdownMono(interleaved: interleaved, channels: channels)
        } else {
            frameCount = length / (MemoryLayout<Int16>.size * channels)
            let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: frameCount * channels)
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            let scale = 1 / Float(Int16.max)
            for i in 0..<(frameCount * channels) {
                interleaved[i] = Float(samples[i]) * scale
            }
            mono = PCMResampler.mixdownMono(interleaved: interleaved, channels: channels)
        }
        let hostTime: UInt64
        if sampleBuffer.presentationTimeStamp.isValid {
            hostTime = AVAudioTime.hostTime(forSeconds: sampleBuffer.presentationTimeStamp.seconds)
        } else {
            hostTime = mach_absolute_time()
        }
        onSamples?(Sample(mono: mono, sampleRate: format.mSampleRate, hostTime: hostTime))
    }
}