import AVFoundation
import CoreAudio
import Foundation

/// Hardware I/O latency reported by Core Audio and AVAudioEngine.
/// Used to convert tap render timestamps and mic capture timestamps onto a
/// common "in the room" timeline. Never a hardcoded fudge.
struct DeviceIOLatency: Sendable, Equatable {
    var outputDeviceName: String
    var inputDeviceName: String
    var outputSampleRate: Double
    var inputSampleRate: Double
    var outputDeviceFrames: UInt32
    var outputSafetyFrames: UInt32
    var outputBufferFrames: UInt32
    var inputDeviceFrames: UInt32
    var inputSafetyFrames: UInt32
    var inputBufferFrames: UInt32
    var inputPresentationSeconds: TimeInterval
    var outputPresentationSeconds: TimeInterval

    var outputPipelineSeconds: TimeInterval {
        seconds(outputDeviceFrames + outputSafetyFrames + outputBufferFrames, rate: outputSampleRate)
    }

    var inputPipelineSeconds: TimeInterval {
        seconds(inputDeviceFrames + inputSafetyFrames + inputBufferFrames, rate: inputSampleRate)
    }

    /// Far (process tap) is stamped at render time. Adding the HAL output
    /// pipeline (device + safety + buffer) yields speaker presentation time.
    var farRenderToPresentationSeconds: TimeInterval { outputPipelineSeconds }

    /// Near (mic tap) host time is at the input node. Subtracting the HAL
    /// input pipeline yields when the wavefront hit the capsule.
    var nearNodeToCapsuleSeconds: TimeInterval { inputPipelineSeconds }

    var summary: String {
        """
        I/O latency
          output: \(outputDeviceName) \(outputSampleRate) Hz
            device \(outputDeviceFrames) frames (\(ms(outputDeviceFrames, rate: outputSampleRate))) \
        safety \(outputSafetyFrames) frames (\(ms(outputSafetyFrames, rate: outputSampleRate))) \
        buffer \(outputBufferFrames) frames (\(ms(outputBufferFrames, rate: outputSampleRate))) \
        pipeline \(String(format: "%.2f", outputPipelineSeconds * 1_000)) ms \
        presentation \(String(format: "%.2f", outputPresentationSeconds * 1_000)) ms
          input: \(inputDeviceName) \(inputSampleRate) Hz
            device \(inputDeviceFrames) frames (\(ms(inputDeviceFrames, rate: inputSampleRate))) \
        safety \(inputSafetyFrames) frames (\(ms(inputSafetyFrames, rate: inputSampleRate))) \
        buffer \(inputBufferFrames) frames (\(ms(inputBufferFrames, rate: inputSampleRate))) \
        pipeline \(String(format: "%.2f", inputPipelineSeconds * 1_000)) ms \
        presentation \(String(format: "%.2f", inputPresentationSeconds * 1_000)) ms
        """
    }

    static func measure(inputPresentationSeconds: TimeInterval = 0, outputPresentationSeconds: TimeInterval = 0) -> DeviceIOLatency {
        let output = device(kAudioHardwarePropertyDefaultOutputDevice)
        let input = device(kAudioHardwarePropertyDefaultInputDevice)
        return DeviceIOLatency(
            outputDeviceName: name(output),
            inputDeviceName: name(input),
            outputSampleRate: float64(output, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            inputSampleRate: float64(input, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            outputDeviceFrames: uint32(output, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput),
            outputSafetyFrames: uint32(output, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput),
            outputBufferFrames: uint32(output, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputDeviceFrames: uint32(input, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeInput),
            inputSafetyFrames: uint32(input, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeInput),
            inputBufferFrames: uint32(input, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputPresentationSeconds: inputPresentationSeconds,
            outputPresentationSeconds: outputPresentationSeconds
        )
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func uint32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func float64(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func name(_ object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cfName)
        return (cfName?.takeRetainedValue() as String?) ?? "unknown"
    }

    private func seconds(_ frames: UInt32, rate: Double) -> TimeInterval {
        guard rate > 0 else { return 0 }
        return Double(frames) / rate
    }

    private func ms(_ frames: UInt32, rate: Double) -> String {
        String(format: "%.2f ms", seconds(frames, rate: rate) * 1_000)
    }
}
