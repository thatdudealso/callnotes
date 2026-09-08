import AVFoundation
import Darwin
import Foundation

@main
enum CaptureHarnessPlaybackMain {
    static func main() {
        do {
            let player = try TonePlayer(sampleRate: 48_000)
            try player.start()
            while getppid() != 1 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            }
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}

private final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
    }

    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "CallNotesCaptureHarnessPlayback", code: 1)
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "CallNotesCaptureHarnessPlayback", code: 2)
        }
        let clickEvery = Int(sampleRate * 0.25)
        for i in 0..<Int(frames) {
            let tone = sin(2 * Double.pi * 1000 * Double(i) / sampleRate) * 0.4
            let click = (i % clickEvery) < 80 ? 0.85 : 0.0
            channel[i] = Float(tone + click)
        }
        try engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
    }
}
