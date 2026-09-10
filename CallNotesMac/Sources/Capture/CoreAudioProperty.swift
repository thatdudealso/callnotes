import CoreAudio
import Foundation

enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) throws -> T {
        var address = address(selector, scope: scope)
        let data = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { data.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, data)
        try check(status)
        return data.pointee
    }

    static func getArray<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer))
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func getString(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        var cfString: Unmanaged<CFString>?
        try check(withUnsafeMutablePointer(to: &cfString) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        })
        guard let value = cfString?.takeRetainedValue() as String? else {
            throw CaptureError.coreAudio(status: kAudioHardwareUnspecifiedError)
        }
        return value
    }

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(status: status) }
    }
}

enum CaptureError: Error, Sendable {
    case coreAudio(status: OSStatus)
    case tapCreationFailed(status: OSStatus)
    case aggregateCreationFailed(status: OSStatus)
    case noDefaultDevice
    case alreadyRunning
    case notRunning
    case permissionDenied(String)
    case screenCaptureFallbackFailed(String)
}
