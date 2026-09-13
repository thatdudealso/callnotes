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
    private var player: AVAudioPlayer?

    func play(_ policy: ConsentPolicy) -> [Int16]? {
        guard let pcm = ConsentAnnouncement.injection(for: policy) else { return nil }
        speak(ConsentPolicy.spokenLine)
        playTone(pcm)
        logger.info("consent announcement injected policy=\(policy.rawValue, privacy: .public)")
        return pcm
    }

    private func speak(_ line: String) {
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
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
