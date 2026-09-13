import AVFoundation
import CallNotesCore
import Foundation
import os

/// Plays the consent announcement into the default output and returns its tone
/// for inclusion in the captured recording.
@MainActor
final class ConsentToneInjector {
    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "Consent")
    private let synthesizer = AVSpeechSynthesizer()
    private let renderer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var speechResampler: StreamingPCMResampler?

    func play(_ policy: ConsentPolicy, injectPCM: @escaping @Sendable ([Int16]) -> Void) {
        guard let tone = ConsentAnnouncement.injection(for: policy) else { return }
        speak(ConsentPolicy.spokenLine)
        render(ConsentPolicy.spokenLine, then: tone, injectPCM: injectPCM)
        playTone(tone)
        logger.info("consent announcement injected policy=\(policy.rawValue, privacy: .public)")
    }

    private func speak(_ line: String) {
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    private func render(
        _ line: String,
        then tone: [Int16],
        injectPCM: @escaping @Sendable ([Int16]) -> Void
    ) {
        renderer.stopSpeaking(at: .immediate)
        speechResampler = nil
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        renderer.write(utterance) { [weak self] buffer in
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            let samples = Self.monoSamples(from: pcmBuffer)
            let sampleRate = pcmBuffer.format.sampleRate
            let finished = pcmBuffer.frameLength == 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !samples.isEmpty {
                    if self.speechResampler?.inputSampleRate != sampleRate {
                        self.speechResampler = StreamingPCMResampler(inputSampleRate: sampleRate)
                    }
                    injectPCM(self.speechResampler?.resampleMonoToInt16(samples) ?? [])
                }
                if finished {
                    injectPCM(tone)
                    self.speechResampler = nil
                }
            }
        }
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frameCount)
        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    samples[frame] += channels[channel][frame] / Float(channelCount)
                }
            }
            return samples
        }
        if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    samples[frame] += Float(channels[channel][frame]) / Float(Int16.max) / Float(channelCount)
                }
            }
        }
        return samples
    }

    private func playTone(_ pcm: [Int16]) {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("callnotes-consent-\(UUID().uuidString).caf")
            var bytes = Data(count: pcm.count * 2)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                for index in pcm.indices {
                    base[index] = pcm[index]
                }
            }
            try ChannelAudio.writeMonoCAF(pcm16: bytes, sampleRate: Double(ConsentAnnouncement.toneSampleRate), to: url)
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            logger.error("consent tone playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
