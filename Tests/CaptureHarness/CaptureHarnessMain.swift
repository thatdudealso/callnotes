import AVFoundation
import CallNotesCore
import Darwin
import Foundation

/// Phase 1 capture harness (plan section 16.3).
///
/// Plays a synthetic click+tone through the default output (stand-in for a
/// live call's far channel) while capturing system audio + microphone into a
/// 2-channel CAF. Asserts both channels non-silent and aligned within 50 ms.
///
/// Usage: `Scripts/run-capture-harness.sh`  (or the CallNotesCaptureHarness tool)
@main
enum CaptureHarnessMain {
    static func main() async {
        do {
            let result = try await CaptureHarness().run()
            print(result.summary)
            if result.passed {
                exit(0)
            } else {
                exit(1)
            }
        } catch CaptureHarnessError.permissionDenied(let message) {
            fputs("PERMISSION: \(message)\n", stderr)
            exit(2)
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}

enum CaptureHarnessError: Error, CustomStringConvertible {
    case permissionDenied(String)
    case captureFailed(String)

    var description: String {
        switch self {
        case .permissionDenied(let message), .captureFailed(let message):
            return message
        }
    }
}

struct CaptureHarnessResult: Sendable {
    var cafURL: URL
    var farSource: String
    var nearSilent: Bool
    var farSilent: Bool
    var lagMilliseconds: Double
    var aligned: Bool
    var frames: Int

    var passed: Bool {
        !nearSilent && !farSilent && aligned
    }

    var summary: String {
        """
        Capture harness
          file: \(cafURL.path)
          far source: \(farSource)
          frames: \(frames)
          near silent: \(nearSilent)
          far silent: \(farSilent)
          lag: \(String(format: "%.1f", lagMilliseconds)) ms
          aligned (<= 50 ms): \(aligned)
          result: \(passed ? "PASS" : "FAIL")
        """
    }
}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CaptureHarnessError.captureFailed("timed out after \(seconds)s")
        }
        guard let result = try await group.next() else {
            throw CaptureHarnessError.captureFailed("timed out")
        }
        group.cancelAll()
        return result
    }
}

struct CaptureHarness {
    var duration: TimeInterval = 3.0

    func run() async throws -> CaptureHarnessResult {
        try requestMicrophone()

        let callID = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-harness-\(callID.uuidString).caf")

        let player = try TonePlayer(sampleRate: 48_000)
        try player.start()
        try await Task.sleep(for: .milliseconds(250))

        let capture = AudioCapture()
        do {
            try await withTimeout(seconds: 8) {
                try await capture.start(
                    AudioCapture.Configuration(
                        outputURL: url,
                        processObjectIDs: [],
                        observedBundleIDs: [],
                        enableMicrophone: true,
                        enableVoiceProcessing: false,
                        enableScreenCaptureFallback: false
                    )
                )
            }
        } catch {
            player.stop()
            throw CaptureHarnessError.permissionDenied(
                """
                System audio capture was blocked (\(error)). Grant CallNotesCaptureHarness \
                (or this terminal) access in System Settings → Privacy & Security → \
                Screen & System Audio Recording. Click System Audio Recording Only, enable \
                CallNotesCaptureHarness (or Terminal if you launched via the script), then \
                re-run Scripts/run-capture-harness.sh.
                """
            )
        }

        capture.beginCommittedWrite()
        try await Task.sleep(for: .seconds(duration))
        player.stop()
        try await Task.sleep(for: .milliseconds(200))
        let written = try await capture.stop()

        let channels = try StereoCAFReader.read(written)
        let analysis = CaptureAlignment.analyze(
            near: channels.near,
            far: channels.far,
            sampleRate: channels.sampleRate
        )
        return CaptureHarnessResult(
            cafURL: written,
            farSource: capture.farSource.rawValue,
            nearSilent: analysis.nearSilent,
            farSilent: analysis.farSilent,
            lagMilliseconds: analysis.lagSeconds * 1_000,
            aligned: analysis.isAligned,
            frames: channels.near.count
        )
    }

    private func requestMicrophone() throws {
        // CLI tools cannot present a TCC dialog reliably; never block on
        // requestAccess. The captain grants Microphone in System Settings.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        default:
            throw CaptureHarnessError.permissionDenied(
                """
                Microphone access is not granted. Open System Settings → Privacy & Security → \
                Microphone, enable CallNotesCaptureHarness (or Terminal if launched via the \
                script), then re-run Scripts/run-capture-harness.sh.
                """
            )
        }
    }
}

/// Plays a 1 kHz tone with a periodic impulse so alignment is measurable.
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.6
    }

    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CaptureHarnessError.captureFailed("Could not allocate playback buffer")
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else {
            throw CaptureHarnessError.captureFailed("Could not fill playback buffer")
        }
        let clickEvery = Int(sampleRate * 0.25)
        for i in 0..<Int(frames) {
            let tone = sin(2 * Double.pi * 1000 * Double(i) / sampleRate) * 0.25
            let click = (i % clickEvery) < 80 ? 0.7 : 0.0
            channel[i] = Float(tone + click)
        }
        try engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
