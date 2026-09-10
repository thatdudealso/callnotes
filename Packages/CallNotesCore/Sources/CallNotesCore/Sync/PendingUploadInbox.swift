import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Metadata carried with an audio file uploaded from an iPhone.
public struct CallUploadMetadata: Codable, Sendable, Equatable {
    public var source: CallSource
    public var startedAt: Date?
    public var counterpartyName: String?

    public init(source: CallSource, startedAt: Date? = nil, counterpartyName: String? = nil) {
        self.source = source
        self.startedAt = startedAt
        self.counterpartyName = counterpartyName
    }

    public static func sidecarURL(nextTo audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("json")
    }

    public func writeSidecar(nextTo audioURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.sidecarURL(nextTo: audioURL), options: .atomic)
    }

    public static func loadSidecar(nextTo audioURL: URL) -> CallUploadMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecarURL(nextTo: audioURL)) else { return nil }
        return try? decoder.decode(CallUploadMetadata.self, from: data)
    }
}

/// A durable upload entry. `audioURL` always points inside the App Group inbox.
public struct PendingUpload: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var audioURL: URL
    public var metadata: CallUploadMetadata
    public var createdAt: Date
    public var retryCount: Int
    public var nextAttemptAt: Date?

    public init(
        id: UUID = UUID(),
        audioURL: URL,
        metadata: CallUploadMetadata,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.audioURL = audioURL
        self.metadata = metadata
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
    }
}

public enum PendingUploadInboxError: Error, LocalizedError, Equatable {
    case sourceFileMissing
    case unknownUpload

    public var errorDescription: String? {
        switch self {
        case .sourceFileMissing: "The shared audio file is no longer available."
        case .unknownUpload: "That pending upload no longer exists."
        }
    }
}

/// File-backed, App Group-safe queue shared by the Share Extension and app.
///
/// The extension completes only after `enqueue` has copied the audio and
/// atomically recorded its manifest. A newly launched app can therefore resume
/// a background transfer after the sharing process has been terminated.
public actor PendingUploadInbox {
    private let directory: URL
    private let uploadsDirectory: URL
    private let manifestURL: URL
    private let manifestLock: ManifestLock
    private var entries: [PendingUpload]

    public init(directory: URL) throws {
        let uploadsDirectory = directory.appendingPathComponent("uploads", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("pending-uploads.json")
        let manifestLock = ManifestLock(url: directory.appendingPathComponent("pending-uploads.lock"))
        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        let entries = try manifestLock.withExclusiveLock { try Self.loadManifest(at: manifestURL) }
        self.directory = directory
        self.uploadsDirectory = uploadsDirectory
        self.manifestURL = manifestURL
        self.manifestLock = manifestLock
        self.entries = entries
    }

    public func enqueue(audioAt sourceURL: URL, metadata: CallUploadMetadata) throws -> PendingUpload {
        try withManifestLock {
            reload()
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw PendingUploadInboxError.sourceFileMissing
            }
            let suffix = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            let destination = uploadsDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let entry = PendingUpload(audioURL: destination, metadata: metadata)
            entries.append(entry)
            try persist()
            return entry
        }
    }

    public func pending(now: Date = Date()) -> [PendingUpload] {
        (try? withManifestLock {
            reload()
            return entries.filter { entry in
                guard FileManager.default.fileExists(atPath: entry.audioURL.path) else { return false }
                return entry.nextAttemptAt.map { $0 <= now } ?? true
            }.sorted { $0.createdAt < $1.createdAt }
        }) ?? []
    }

    public func markFailed(_ id: UUID, at date: Date = Date()) throws {
        try withManifestLock {
            reload()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw PendingUploadInboxError.unknownUpload
            }
            entries[index].retryCount += 1
            let delay = min(pow(2, Double(entries[index].retryCount)) * 15, 6 * 60 * 60)
            entries[index].nextAttemptAt = date.addingTimeInterval(delay)
            try persist()
        }
    }

    /// A rejected token is not a transient failure: the job waits for the user
    /// to pair again rather than sitting out an exponential backoff.
    public func clearBackoff(_ id: UUID) throws {
        try withManifestLock {
            reload()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw PendingUploadInboxError.unknownUpload
            }
            entries[index].retryCount = 0
            entries[index].nextAttemptAt = nil
            try persist()
        }
    }

    public func markCompleted(_ id: UUID) throws {
        try withManifestLock {
            reload()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw PendingUploadInboxError.unknownUpload
            }
            let entry = entries.remove(at: index)
            try? FileManager.default.removeItem(at: entry.audioURL)
            try persist()
        }
    }

    /// The manifest, not this actor, is the source of truth: the Share Extension
    /// and the app each hold their own inbox over the same App Group directory.
    private func reload() {
        guard let stored = try? Self.loadManifest(at: manifestURL) else { return }
        entries = stored
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func withManifestLock<T>(_ operation: () throws -> T) throws -> T {
        try manifestLock.withExclusiveLock(operation)
    }

    private static func loadManifest(at url: URL) throws -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingUpload].self, from: Data(contentsOf: url))
    }
}

private final class ManifestLock: @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let processLock = ManifestLockRegistry.lock(for: url.path)
        processLock.lock()
        defer { processLock.unlock() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try operation()
    }
}

private final class ManifestLockRegistry: @unchecked Sendable {
    private static let shared = ManifestLockRegistry()
    private let lock = NSLock()
    private var locks: [String: NSLock] = [:]

    static func lock(for path: String) -> NSLock {
        shared.lock.withLock {
            if let lock = shared.locks[path] { return lock }
            let lock = NSLock()
            shared.locks[path] = lock
            return lock
        }
    }
}

public enum SharedAudioStaging {
    public final class Lease: @unchecked Sendable {
        public let audioURL: URL
        private let lockURL: URL
        private var descriptor: Int32
        private let lock = NSLock()

        public init(audioURL: URL) throws {
            self.audioURL = audioURL
            lockURL = audioURL.appendingPathExtension("lock")
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
            descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw CocoaError(.fileWriteUnknown)
            }
        }

        deinit { release() }

        public func release() {
            let descriptor = lock.withLock { () -> Int32 in
                let held = self.descriptor
                self.descriptor = -1
                return held
            }
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            try? FileManager.default.removeItem(at: lockURL)
        }
    }

    public static func sweepOrphans(in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for audioURL in contents where audioURL.pathExtension != "lock" {
            let lockURL = audioURL.appendingPathExtension("lock")
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: lockURL)
                flock(descriptor, LOCK_UN)
            }
            close(descriptor)
        }
    }
}

/// Conservative extraction for titles emitted by Notes call recordings.
/// Unknown formats remain uploadable with no guessed metadata.
public enum SharedRecordingTitleParser {
    public static func parse(_ title: String) -> CallUploadMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expression = #/^Call with (.+?),\s*(.+)$/#
        guard let match = trimmed.wholeMatch(of: expression) else { return nil }
        let name = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
        let dateText = String(match.output.2).trimmingCharacters(in: .whitespacesAndNewlines)
        return CallUploadMetadata(
            source: .iphoneRecording,
            startedAt: date(from: dateText),
            counterpartyName: name.isEmpty ? nil : name
        )
    }

    private static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.date(from: text)
    }
}
