import Foundation

/// On-disk locations for the import inbox (plan Phase 5).
///
/// Finder's iCloud Drive folder is `~/Library/Mobile Documents/com~apple~CloudDocs`.
/// Dropping a supported audio file into `CallNotes/Inbox` there is the Files
/// path from the iPhone.
/// When iCloud Drive is off, the watcher falls back to Application Support.
public enum InboxPaths: Sendable {
    public static let folderName = "CallNotes"
    public static let inboxName = "Inbox"
    public static let seenIndexFileName = "inbox-seen.json"

    public static let audioExtensions: Set<String> = ["m4a", "caf", "wav", "aiff", "aif", "aac"]

    public static func iCloudDriveRoot(fileManager: FileManager = .default) -> URL {
        #if os(macOS)
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        #else
        // The Mac import watcher is the only caller that uses the desktop
        // iCloud Drive location. Keep this shared type iOS-buildable without
        // inventing a path outside the app sandbox.
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallNotes-iCloud-unavailable", isDirectory: true)
        #endif
    }

    public static func iCloudDriveInbox(fileManager: FileManager = .default) -> URL? {
        let root = iCloudDriveRoot(fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        return root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(inboxName, isDirectory: true)
    }

    public static func localInbox(fileManager: FileManager = .default) throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(CallAudioPaths.applicationSupportFolder, isDirectory: true)
            .appendingPathComponent(inboxName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Prefers the iCloud Drive inbox when that tree exists, otherwise the
    /// local Application Support inbox so imports still work offline.
    public static func resolvedInbox(fileManager: FileManager = .default) throws -> URL {
        if let iCloud = iCloudDriveInbox(fileManager: fileManager) {
            try fileManager.createDirectory(at: iCloud, withIntermediateDirectories: true)
            return iCloud
        }
        return try localInbox(fileManager: fileManager)
    }

    public static func seenIndexURL(fileManager: FileManager = .default) throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(CallAudioPaths.applicationSupportFolder, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(seenIndexFileName)
    }
}

/// Decides whether a path in the inbox is a finished, importable audio file.
public enum InboxCandidate: Sendable {
    public static func isImportable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        guard !name.hasSuffix(".icloud") else { return false }
        guard !name.hasSuffix(".download") else { return false }
        let ext = url.pathExtension.lowercased()
        guard InboxPaths.audioExtensions.contains(ext) else { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        if let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) {
            if values.isRegularFile == false { return false }
            if values.isUbiquitousItem == true,
                values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
            {
                return false
            }
        }
        return true
    }
}
