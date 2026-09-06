import AVFoundation
import CallNotesCore
import CoreAudio
import Foundation
import os

/// Core Audio process tap of a call app's output, with a global-tap fallback
/// that excludes CallNotes itself. IO runs on a dedicated queue; samples are
/// mixed down to mono Float at the tap's native rate.
final class ProcessTapCapture: @unchecked Sendable {
    struct Sample: Sendable {
        var mono: [Float]
        var sampleRate: Double
        var hostTime: UInt64
    }

    var onSamples: (@Sendable (Sample) -> Void)?

    private let logger = Logger(subsystem: "com.thatdudealso.callnotes", category: "ProcessTap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ioQueue: DispatchQueue?
    private var nativeSampleRate: Double = 48_000
    private var nativeChannels: Int = 2
    private(set) var isRunning = false
    private(set) var usedGlobalFallback = false

    func start(processObjectIDs: [AudioObjectID], excludeObjectIDs: [AudioObjectID], bundleIDs: [String]) throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }

        if processObjectIDs.isEmpty {
            try startTap(description: makeGlobalTapDescription(excludeObjectIDs: excludeObjectIDs))
            usedGlobalFallback = true
        } else {
            do {
                try startTap(
                    description: makeProcessTapDescription(processObjectIDs: processObjectIDs, bundleIDs: bundleIDs)
                )
                usedGlobalFallback = false
            } catch {
                logger.error("Process tap failed (\(String(describing: error), privacy: .public)); falling back to global tap")
                stopInternal()
                try startTap(description: makeGlobalTapDescription(excludeObjectIDs: excludeObjectIDs))
                usedGlobalFallback = true
            }
        }
        isRunning = true
    }

    func stop() {
        stopInternal()
        isRunning = false
    }

    deinit {
        stopInternal()
    }

    private func makeProcessTapDescription(processObjectIDs: [AudioObjectID], bundleIDs: [String]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        configure(description)
        if !bundleIDs.isEmpty {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    private func makeGlobalTapDescription(excludeObjectIDs: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeObjectIDs)
        configure(description)
        return description
    }

    private func configure(_ description: CATapDescription) {
        description.uuid = UUID()
        description.name = "CallNotes Far Channel"
        description.muteBehavior = .unmuted
        description.isPrivate = true
    }

    private func startTap(description: CATapDescription) throws {
        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(status: tapStatus)
        }
        tapID = createdTap

        let format: AudioStreamBasicDescription = try CoreAudioProperty.get(
            object: tapID,
            selector: kAudioTapPropertyFormat
        )
        nativeSampleRate = format.mSampleRate
        nativeChannels = Int(max(1, format.mChannelsPerFrame))
        logger.info("Tap \(self.tapID, privacy: .public) format \(format.mSampleRate, format: .fixed(precision: 0)) Hz \(format.mChannelsPerFrame) ch")

        let outputUID = try AudioProcessEnumerator.defaultOutputDeviceUID()
        let tapUID = description.uuid.uuidString
        let aggregateUID = "com.thatdudealso.callnotes.tap.\(UUID().uuidString)"
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallNotes Far Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &createdAggregate)
        guard aggStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(status: aggStatus)
        }
        aggregateID = createdAggregate

        let queue = DispatchQueue(label: "com.thatdudealso.callnotes.tap-io", qos: .userInteractive)
        ioQueue = queue
        var createdProc: AudioDeviceIOProcID?
        try CoreAudioProperty.check(
            AudioDeviceCreateIOProcIDWithBlock(&createdProc, aggregateID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
                self?.handleIO(inInputData: inInputData, inInputTime: inInputTime)
            }
        )
        guard let createdProc else {
            throw CaptureError.coreAudio(status: kAudioHardwareUnspecifiedError)
        }
        ioProcID = createdProc
        try CoreAudioProperty.check(AudioDeviceStart(aggregateID, createdProc))
    }

    private func handleIO(inInputData: UnsafePointer<AudioBufferList>?, inInputTime: UnsafePointer<AudioTimeStamp>?) {
        guard let inInputData else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard !abl.isEmpty else { return }

        var mono: [Float] = []
        let first = abl[0]
        let frameCount = Int(first.mDataByteSize) / max(1, Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        guard frameCount > 0, let data = first.mData else { return }

        if abl.count == 1, first.mNumberChannels >= 2 {
            let samples = data.assumingMemoryBound(to: Float.self)
            let channels = Int(first.mNumberChannels)
            mono = [Float](repeating: 0, count: frameCount)
            let inv = 1 / Float(channels)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += samples[frame * channels + ch]
                }
                mono[frame] = sum * inv
            }
        } else if abl.count >= 2 {
            let left = first.mData?.assumingMemoryBound(to: Float.self)
            let right = abl[1].mData?.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                let l = left?[frame] ?? 0
                let r = right?[frame] ?? 0
                mono[frame] = 0.5 * (l + r)
            }
        } else {
            let samples = data.assumingMemoryBound(to: Float.self)
            mono = Array(UnsafeBufferPointer(start: samples, count: frameCount))
        }

        let hostTime = inInputTime?.pointee.mHostTime ?? mach_absolute_time()
        onSamples?(Sample(mono: mono, sampleRate: nativeSampleRate, hostTime: hostTime))
    }

    private func stopInternal() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        ioQueue = nil
    }
}