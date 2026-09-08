import AVFoundation
import CallNotesCore
import Foundation
import os

/// Near-end capture: AVAudioEngine input with voice processing so the
/// far-end bleed is stripped when the user is on speaker.
final class MicrophoneCapture: @unchecked Sendable {
    struct Sample: Sendable {
        var mono: [Float]
        var sampleRate: Double
        var hostTime: UInt64
    }

    var onSamples: (@Sendable (Sample) -> Void)?

    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "Microphone")
    private let engine = AVAudioEngine()
    private(set) var isRunning = false
    private(set) var voiceProcessingEnabled = false

    var inputPresentationLatency: TimeInterval {
        engine.inputNode.presentationLatency
    }

    func start(enableVoiceProcessing: Bool = true) throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        let input = engine.inputNode
        var started = false
        defer {
            if !started {
                reset()
            }
        }
        if enableVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            } catch {
                logger.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
                voiceProcessingEnabled = false
            }
        }
        let format = input.outputFormat(forBus: 0)
        let channels = Int(max(1, format.channelCount))
        logger.info("Mic format \(format.sampleRate, format: .fixed(precision: 0)) Hz \(channels) ch")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
            self?.handle(buffer: buffer, time: time, channels: channels)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        started = true
        logger.info("Mic engine started")
    }

    func stop() {
        reset()
    }

    private func reset() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
        }
        isRunning = false
    }

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime, channels: Int) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        if let floatChannels = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let src = floatChannels[0]
                for i in 0..<(frames * channels) {
                    interleaved[i] = src[i]
                }
            } else {
                for frame in 0..<frames {
                    for ch in 0..<channels {
                        interleaved[frame * channels + ch] = floatChannels[ch][frame]
                    }
                }
            }
        } else if let int16 = buffer.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            if buffer.format.isInterleaved {
                let src = int16[0]
                for i in 0..<(frames * channels) {
                    interleaved[i] = Float(src[i]) * scale
                }
            } else {
                for frame in 0..<frames {
                    for ch in 0..<channels {
                        interleaved[frame * channels + ch] = Float(int16[ch][frame]) * scale
                    }
                }
            }
        }
        let mono = PCMResampler.mixdownMono(interleaved: interleaved, channels: channels)
        onSamples?(
            Sample(
                mono: mono,
                sampleRate: buffer.format.sampleRate,
                hostTime: time.hostTime
            )
        )
    }
}
