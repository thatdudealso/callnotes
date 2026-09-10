import Foundation

/// On-disk layout for Mac captures: `~/Library/Application Support/CallNotes/audio/<call_id>.caf`.
public enum CallAudioPaths: Sendable {
    public static let applicationSupportFolder = "CallNotes"
    public static let audioFolder = "audio"

    public static func audioDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolder, isDirectory: true)
            .appendingPathComponent(audioFolder, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func cafURL(callID: UUID, fileManager: FileManager = .default) throws -> URL {
        try audioDirectory(fileManager: fileManager)
            .appendingPathComponent("\(callID.uuidString).caf")
    }

    public static func importedAudioURL(
        callID: UUID,
        sourceExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let ext = sourceExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let resolved = ext.isEmpty ? "caf" : ext
        return try audioDirectory(fileManager: fileManager)
            .appendingPathComponent("\(callID.uuidString).\(resolved)")
    }
}
