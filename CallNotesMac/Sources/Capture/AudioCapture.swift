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

    struct StreamTiming: Sendable {
        var tapStartedHost: UInt64 = 0
        var micStartedHost: UInt64 = 0
        var firstFarHost: UInt64?
        var firstNearHost: UInt64?
        var firstFarCallbackHost: UInt64?
        var firstNearCallbackHost: UInt64?
        var firstFarFrames: Int = 0
        var firstNearFrames: Int = 0
        var alignShift: Int = 0
        var farTrimmed: Int = 0
        var farPadded: Int = 0
        var nearPadded: Int = 0
    }

    private let streamTiming = Mutex(StreamTiming())
    private let latency = Mutex(CaptureAlignment.LatencyCompensation.none)

    var debugTiming: StreamTiming {
        streamTiming.withLock { $0 }
    }

    var latencyCompensation: CaptureAlignment.LatencyCompensation {
        latency.withLock { $0 }
    }

    private(set) var ioLatency = DeviceIOLatency.measure()

    private struct ResamplerState: Sendable {
        var near: StreamingPCMResampler?
        var far: StreamingPCMResampler?
    }

    private let resamplers = Mutex(ResamplerState())

    private var writer: StereoCAFWriter?
    private var writing = false
    private(set) var isRunning = false
    private(set) var farSource: FarSource = .none
    private(set) var outputURL: URL?

    var ringSnapshot: [Int16] { ring.snapshot() }

    var channelStartTimes: (near: TimeInterval?, far: TimeInterval?) {
        mixer.withLock { state in
            (
                near: state.nearHost.map(AVHostTime.seconds),
                far: state.farHost.map(AVHostTime.seconds)
            )
        }
    }

    var microphonePresentationLatency: TimeInterval {
        microphone.inputPresentationLatency
    }

    func start(_ configuration: Configuration) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        ring.reset()
        mixer.withLock { $0 = MixerState() }
        streamTiming.withLock { $0 = StreamTiming() }
        resamplers.withLock { $0 = ResamplerState() }
        outputURL = configuration.outputURL
        writer = try StereoCAFWriter(url: configuration.outputURL)
        writing = false
        ioLatency = DeviceIOLatency.measure()
        latency.withLock {
            $0 = CaptureAlignment.LatencyCompensation(
                farRenderToPresentationSeconds: ioLatency.farRenderToPresentationSeconds,
                nearNodeToCapsuleSeconds: ioLatency.nearNodeToCapsuleSeconds
            )
        }

        processTap.onSamples = { [weak self] sample in
            self?.ingest(channel: .far, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }
        microphone.onSamples = { [weak self] sample in
            self?.ingest(channel: .near, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }
        screenFallback.onSamples = { [weak self] sample in
            self?.ingest(channel: .far, sample: sample.mono, sampleRate: sample.sampleRate, hostTime: sample.hostTime)
        }

        // Start the tap first. Creating the aggregate after AVAudioEngine is
        // already running tears down HAL I/O and starves the mic tap.
        let exclude = [AudioProcessEnumerator.ownProcessObjectID()].compactMap { $0 }
        do {
            try processTap.start(
                processObjectIDs: configuration.processObjectIDs,
                excludeObjectIDs: exclude,
                bundleIDs: configuration.observedBundleIDs
            )
            farSource = processTap.usedGlobalFallback ? .globalTap : .processTap
            streamTiming.withLock { $0.tapStartedHost = mach_absolute_time() }
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

        do {
            if configuration.enableMicrophone {
                try microphone.start(enableVoiceProcessing: configuration.enableVoiceProcessing)
                streamTiming.withLock { $0.micStartedHost = mach_absolute_time() }
                ioLatency = DeviceIOLatency.measure(
                    inputPresentationSeconds: microphone.inputPresentationLatency
                )
                latency.withLock {
                    $0 = CaptureAlignment.LatencyCompensation(
                        farRenderToPresentationSeconds: ioLatency.farRenderToPresentationSeconds,
                        nearNodeToCapsuleSeconds: ioLatency.nearNodeToCapsuleSeconds
                    )
                }
            }
        } catch {
            microphone.stop()
            processTap.stop()
            await screenFallback.stop()
            writer?.close()
            writer = nil
            outputURL = nil
            farSource = .none
            throw error
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
        let callbackHost = mach_absolute_time()
        streamTiming.withLock { timing in
            switch channel {
            case .near:
                if timing.firstNearHost == nil {
                    timing.firstNearHost = hostTime
                    timing.firstNearCallbackHost = callbackHost
                    timing.firstNearFrames = sample.count
                }
            case .far:
                if timing.firstFarHost == nil {
                    timing.firstFarHost = hostTime
                    timing.firstFarCallbackHost = callbackHost
                    timing.firstFarFrames = sample.count
                }
            }
        }
        let int16 = resamplers.withLock { state in
            switch channel {
            case .near:
                if state.near?.inputSampleRate != sampleRate {
                    state.near = StreamingPCMResampler(inputSampleRate: sampleRate)
                }
                return state.near?.resampleMonoToInt16(sample) ?? []
            case .far:
                if state.far?.inputSampleRate != sampleRate {
                    state.far = StreamingPCMResampler(inputSampleRate: sampleRate)
                }
                return state.far?.resampleMonoToInt16(sample) ?? []
            }
        }
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
                let compensation = latency.withLock { $0 }
                let farStart = AVHostTime.seconds(farHost)
                let nearStart = AVHostTime.seconds(nearHost)
                let shift = compensation.sampleShift(
                    farStart: farStart,
                    nearStart: nearStart,
                    sampleRate: sampleRate
                )
                let pads = CaptureAlignment.leadingAdjustments(shift: shift)
                if pads.farPad > 0 {
                    state.far.insert(contentsOf: repeatElement(0, count: pads.farPad), at: 0)
                }
                if pads.nearPad > 0 {
                    state.near.insert(contentsOf: repeatElement(0, count: pads.nearPad), at: 0)
                }
                var dropped = 0
                if pads.farTrim > 0 {
                    dropped = min(pads.farTrim, state.far.count)
                    if dropped > 0 {
                        state.far.removeFirst(dropped)
                        let droppedSeconds = Double(dropped) / sampleRate
                        state.farHost = AVHostTime.adding(farHost, seconds: droppedSeconds)
                    }
                }
                streamTiming.withLock { timing in
                    timing.alignShift = shift
                    timing.farTrimmed = dropped
                    timing.farPadded = pads.farPad
                    timing.nearPadded = pads.nearPad
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

    static func adding(_ hostTime: UInt64, seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let deltaNanos = seconds * 1_000_000_000
        let deltaHost = deltaNanos * Double(info.denom) / Double(info.numer)
        let rounded = deltaHost.rounded()
        if rounded >= 0 {
            return hostTime &+ UInt64(rounded)
        }
        let magnitude = UInt64((-rounded).rounded())
        return hostTime > magnitude ? hostTime - magnitude : 0
    }
}
