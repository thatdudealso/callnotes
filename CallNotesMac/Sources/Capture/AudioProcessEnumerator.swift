import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable, Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String?
    var isRunningOutput: Bool
}

enum AudioProcessEnumerator {
    static func list() throws -> [AudioProcessInfo] {
        let ids: [AudioObjectID] = try CoreAudioProperty.getArray(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        return ids.compactMap { objectID in
            let pid: pid_t
            do {
                pid = try CoreAudioProperty.get(object: objectID, selector: kAudioProcessPropertyPID)
            } catch {
                return nil
            }
            let bundleID = try? CoreAudioProperty.getString(object: objectID, selector: kAudioProcessPropertyBundleID)
            let running: UInt32 = (try? CoreAudioProperty.get(
                object: objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            )) ?? 0
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: running != 0
            )
        }
    }

    static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var qualifier = pid
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifier,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    static func defaultInputIsRunningSomewhere() -> Bool {
        guard let deviceID: AudioDeviceID = try? CoreAudioProperty.get(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        ), deviceID != kAudioObjectUnknown else {
            return false
        }
        let running: UInt32 = (try? CoreAudioProperty.get(
            object: deviceID,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere
        )) ?? 0
        return running != 0
    }

    static func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioDeviceID = try CoreAudioProperty.get(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        guard deviceID != kAudioObjectUnknown else { throw CaptureError.noDefaultDevice }
        return try CoreAudioProperty.getString(object: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func ownProcessObjectID() -> AudioObjectID? {
        processObjectID(forPID: getpid())
    }
}