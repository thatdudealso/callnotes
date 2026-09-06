import CallNotesCore
import CoreAudio
import Foundation
import os
import Synchronization

/// Two-channel capture: process-tap (or fallback) far end + mic near end,
/// resampled to 16 kHz Int16, written as L=near/R=far CAF, with a 30 s ring
/// so detection debounce and a late STT engine do not lose audio.
final class AudioCapture: @unchecked Sendable {
    struct Configuration: Sendable {
        var outputURL: URL
        var processObjectIDs: [AudioObjectID]
        var observedBundleIDs: [String]
        var enableMicrophone: Bool
        var enableVoiceProcessing: Bool
        var enableScreenCaptureFallback: Bool = true
    }

    enum FarSource: String, Sendable {
        case processTap
        case globalTap
        case screenCaptureKit
        case none
    }

    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "AudioCapture")
    private let processTap = ProcessTapCapture()
    private let microphone = MicrophoneCapture()
    private let screenFallback = ScreenAudioFallback()
    private let ring = AudioRingBuffer()
    private let mixerQueue = DispatchQueue(label: "com.thatdudealso.callnotes.mixer")

    private struct MixerState: Sendable {
        var near: [Int16] = []
        var far: [Int16] = []
        var nearHost: UInt64?
        var farHost: UInt64?
        var didAlignStart = false
    }

    private let mixer = Mutex(MixerState())

    private var writer: StereoCAFWriter?
    private var writing = false
    private(set) var isRunning = false
    private(set) var farSource: FarSource = .none
    private(set) var outputURL: URL?

    var ringSnapshot: [Int16] { ring.snapshot() }

    func start(_ configuration: Configuration) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        ring.reset()
        mixer.withLock { $0 = MixerState() }
        outputURL = configuration.outputURL
        writer = try StereoCAFWriter(url: configuration.outputURL)
        writing = false

        processTap.onSamples = { [weak self] sample in
            self?.ingest(channel: .far, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }
        microphone.onSamples = { [weak self] sample in
            self?.ingest(channel: .near, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }
        screenFallback.onSamples = { [weak self] sample in
            self?.ingest(channel: .far, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }

        let exclude = [AudioProcessEnumerator.ownProcessObjectID()].compactMap { $0 }
        do {
            try processTap.start(
                processObjectIDs: configuration.processObjectIDs,
                excludeObjectIDs: exclude,
                bundleIDs: configuration.observedBundleIDs
            )
            farSource = processTap.usedGlobalFallback ? .globalTap : .processTap
        } catch {
            logger.error("Process tap unavailable (\(String(describing: error), privacy: .public))")
            if configuration.enableScreenCaptureFallback {
                logger.error("trying ScreenCaptureKit")
                do {
                    try await screenFallback.start()
                    farSource = .screenCaptureKit
                } catch {
                    logger.error("ScreenCaptureKit fallback failed: \(String(describing: error), privacy: .public)")
                    farSource = .none
                    throw error
                }
            } else {
                farSource = .none
                throw error
            }
        }

        if configuration.enableMicrophone {
            try microphone.start(enableVoiceProcessing: configuration.enableVoiceProcessing)
        }
        isRunning = true
    }

    /// Begin committing the ring + live samples to the CAF. Call this when
    /// debounce promotes pendingStart to recording so the debounce window is kept.
    func beginCommittedWrite() {
        mixerQueue.sync {
            guard !writing else { return }
            writing = true
            let snapshot = ring.snapshot()
            if !snapshot.isEmpty {
                try? writer?.writeInterleaved(snapshot)
            }
        }
    }

    func stop() async throws -> URL {
        microphone.stop()
        processTap.stop()
        await screenFallback.stop()
        mixerQueue.sync {
            flushRemaining()
            writing = false
            writer?.close()
            writer = nil
        }
        isRunning = false
        guard let outputURL else { throw CaptureError.notRunning }
        return outputURL
    }

    private enum Channel { case near, far }

    private func ingest(channel: Channel, sample: [Float], sampleRate: Double, hostTime: UInt64) {
        let int16 = PCMResampler.resampleMonoToInt16(input: sample, inputSampleRate: sampleRate)
        mixerQueue.async { [weak self] in
            self?.mix(channel: channel, samples: int16, hostTime: hostTime, sampleRate: Double(AudioConstants.localSampleRate))
        }
    }

    private func mix(channel: Channel, samples: [Int16], hostTime: UInt64, sampleRate: Double) {
        mixer.withLock { state in
            switch channel {
            case .near:
                if state.nearHost == nil { state.nearHost = hostTime }
                state.near.append(contentsOf: samples)
            case .far:
                if state.farHost == nil { state.farHost = hostTime }
                state.far.append(contentsOf: samples)
            }
            if !state.didAlignStart, let nearHost = state.nearHost, let farHost = state.farHost {
                let delta = AVHostTime.seconds(farHost) - AVHostTime.seconds(nearHost)
                let shift = Int((delta * sampleRate).rounded())
                if shift > 0 {
                    state.far.insert(contentsOf: repeatElement(0, count: shift), at: 0)
                } else if shift < 0 {
                    state.near.insert(contentsOf: repeatElement(0, count: -shift), at: 0)
                }
                state.didAlignStart = true
            }
        }
        emitPairedFrames()
    }

    private func emitPairedFrames() {
        let pair: (near: [Int16], far: [Int16])? = mixer.withLock { state in
            let frames = min(state.near.count, state.far.count)
            guard frames > 0 else { return nil }
            let near = Array(state.near.prefix(frames))
            let far = Array(state.far.prefix(frames))
            state.near.removeFirst(frames)
            state.far.removeFirst(frames)
            return (near, far)
        }
        guard let pair else { return }
        ring.write(near: pair.near, far: pair.far)
        if writing {
            try? writer?.write(near: pair.near, far: pair.far)
        }
    }

    private func flushRemaining() {
        mixer.withLock { state in
            let frames = max(state.near.count, state.far.count)
            guard frames > 0 else { return }
            if state.near.count < frames {
                state.near.append(contentsOf: repeatElement(0, count: frames - state.near.count))
            }
            if state.far.count < frames {
                state.far.append(contentsOf: repeatElement(0, count: frames - state.far.count))
            }
        }
        emitPairedFrames()
    }
}

private enum AVHostTime {
    static func seconds(_ hostTime: UInt64) -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(hostTime) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }
}