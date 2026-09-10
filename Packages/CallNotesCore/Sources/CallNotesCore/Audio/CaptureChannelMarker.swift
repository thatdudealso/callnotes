import AudioToolbox
import Foundation

public enum CaptureChannelMarkerError: Error, Equatable, Sendable {
    case unwritable(OSStatus)
}

/// CallNotes stamps the CAF info chunk of every 2-channel file it records, so
/// an import can prove L = near / R = far instead of trusting a file
/// extension. Anything without the marker is treated as unknown room audio.
public enum CaptureChannelMarker: Sendable {
    public static let infoKey = "CallNotesChannelLayout"
    public static let nearFarValue = "near-far"

    public static func stampNearFar(_ url: URL) throws {
        var fileID: AudioFileID?
        var status = AudioFileOpenURL(url as CFURL, .readWritePermission, kAudioFileCAFType, &fileID)
        guard status == noErr, let fileID else {
            throw CaptureChannelMarkerError.unwritable(status)
        }
        defer { AudioFileClose(fileID) }
        var info = [infoKey: nearFarValue] as CFDictionary
        status = withUnsafePointer(to: &info) { pointer in
            AudioFileSetProperty(
                fileID,
                kAudioFilePropertyInfoDictionary,
                UInt32(MemoryLayout<CFDictionary>.size),
                pointer
            )
        }
        guard status == noErr else {
            throw CaptureChannelMarkerError.unwritable(status)
        }
    }

    public static func hasNearFarMarker(_ url: URL) -> Bool {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            return false
        }
        defer { AudioFileClose(fileID) }
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var info: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size, pointer)
        }
        guard status == noErr, let dictionary = info?.takeRetainedValue() as? [String: String] else {
            return false
        }
        return dictionary[infoKey] == nearFarValue
    }
}
