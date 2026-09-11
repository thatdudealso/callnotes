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

    /// A blank name is an absent counterparty, not an empty one: every consumer
    /// falls back through `?? "Call"` / `?? "Untitled call"` / `Speaker N`, and
    /// an empty string satisfies none of them.
    public init(source: CallSource, startedAt: Date? = nil, counterpartyName: String? = nil) {
        let name = counterpartyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.startedAt = startedAt
        self.counterpartyName = (name?.isEmpty ?? true) ? nil : name
    }

    /// Decoding is the other way this value is built - from the App Group
    /// manifest an older build wrote, and from the wire on the Mac - so it runs
    /// the same rule rather than assigning the stored name verbatim.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(CallSource.self, forKey: .source),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            counterpartyName: try container.decodeIfPresent(String.self, forKey: .counterpartyName)
        )
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

/// A job the paired Mac permanently refused. The queued copy was the phone's
/// only one, so the drop is recorded durably instead of being announced to
/// whichever process happened to observe the response.
public struct RejectedUpload: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var statusCode: Int
    public var counterpartyName: String?
    public var rejectedAt: Date

    public init(id: UUID, statusCode: Int, counterpartyName: String? = nil, rejectedAt: Date = Date()) {
        self.id = id
        self.statusCode = statusCode
        self.counterpartyName = counterpartyName
        self.rejectedAt = rejectedAt
    }

    /// One sentence for every surface that reports a drop, so the share sheet
    /// and the app's Uploads section cannot drift apart.
    public static func summary(of rejections: [RejectedUpload]) -> String? {
        guard let first = rejections.first else { return nil }
        guard rejections.count > 1 else {
            return UploadRejectedError(statusCode: first.statusCode, counterpartyName: first.counterpartyName)
                .localizedDescription
        }
        return "Your Mac refused \(rejections.count) recordings, so they were removed from the upload queue."
    }
}

/// The Mac answered with a status no retry can change. Surfaced instead of the
/// transport error a caller would otherwise report for the same response.
public struct UploadRejectedError: Error, LocalizedError, Equatable {
    public let statusCode: Int
    public let counterpartyName: String?

    public init(statusCode: Int, counterpartyName: String? = nil) {
        self.statusCode = statusCode
        self.counterpartyName = counterpartyName
    }

    public var errorDescription: String? {
        let subject = counterpartyName.map { "the recording of your call with \($0)" } ?? "this recording"
        return "Your Mac refused \(subject) (HTTP \(statusCode)), so it was removed from the upload queue."
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
///
/// Opening an inbox never takes the cross-process lock: `persist()` renames an
/// atomically written file, so an unlocked read sees one whole manifest or the
/// other, and every operation `reload()`s under the lock before it acts. The
/// first exclusive wait therefore happens on this actor rather than on whatever
/// thread - often the main one - happened to construct it while the Share
/// Extension holds the lock across a multi-hundred-megabyte copy.
public actor PendingUploadInbox {
    private static let rejectionLogLimit = 20

    private let directory: URL
    private let uploadsDirectory: URL
    private let manifestURL: URL
    private let rejectionsURL: URL
    private let manifestLock: ManifestLock
    private let persistenceWriter: @Sendable (URL, Data) throws -> Void
    private var entries: [PendingUpload]

    public init(
        directory: URL,
        persistenceWriter: (@Sendable (URL, Data) throws -> Void)? = nil
    ) throws {
        let uploadsDirectory = directory.appendingPathComponent("uploads", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("pending-uploads.json")
        let manifestLock = ManifestLock(url: directory.appendingPathComponent("pending-uploads.lock"))
        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        let entries = try Self.loadManifest(at: manifestURL)
        self.directory = directory
        self.uploadsDirectory = uploadsDirectory
        self.manifestURL = manifestURL
        self.rejectionsURL = directory.appendingPathComponent("rejected-uploads.json")
        self.manifestLock = manifestLock
        self.persistenceWriter = persistenceWriter ?? { url, data in
            try data.write(to: url, options: .atomic)
        }
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
            let previousEntries = entries
            let entry = PendingUpload(audioURL: destination, metadata: metadata)
            entries.append(entry)
            do {
                try persist()
            } catch {
                entries = previousEntries
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
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
            let previousEntries = entries
            let entry = entries.remove(at: index)
            do {
                try persist()
            } catch {
                entries = previousEntries
                throw error
            }
            try? FileManager.default.removeItem(at: entry.audioURL)
        }
    }

    /// A status no retry can change: the job is dropped rather than backed off
    /// forever. Dropping it destroys the phone's only copy, so the rejection is
    /// logged under the same lock for whichever process next drains it.
    @discardableResult
    public func markRejected(_ id: UUID, statusCode: Int, at date: Date = Date()) throws -> PendingUpload {
        try withManifestLock {
            reload()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw PendingUploadInboxError.unknownUpload
            }
            let previousEntries = entries
            let entry = entries.remove(at: index)
            do {
                try persist()
            } catch {
                entries = previousEntries
                throw error
            }
            var log = Self.loadRejections(at: rejectionsURL)
            log.append(
                RejectedUpload(
                    id: entry.id,
                    statusCode: statusCode,
                    counterpartyName: entry.metadata.counterpartyName,
                    rejectedAt: date
                )
            )
            persistRejections(Array(log.suffix(Self.rejectionLogLimit)))
            try? FileManager.default.removeItem(at: entry.audioURL)
            return entry
        }
    }

    /// Drains the rejection log: a drop the user has been told about must not be
    /// reported again on every later launch.
    public func takeRejections() -> [RejectedUpload] {
        (try? withManifestLock {
            let log = Self.loadRejections(at: rejectionsURL)
            if !log.isEmpty { persistRejections([]) }
            return log
        }) ?? []
    }

    /// Every write to `uploads/` happens under the manifest lock, so a file that
    /// has no entry while the lock is held belongs to a process that died
    /// mid-copy or to a completion whose delete failed. Nothing can reach it
    /// again: `pending()` keys off entries, so it would sit in the App Group
    /// forever otherwise.
    public func sweepOrphans() {
        try? withManifestLock {
            reload()
            let queued = Set(entries.map(\.audioURL.lastPathComponent))
            let staged = (try? FileManager.default.contentsOfDirectory(
                at: uploadsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in staged where !queued.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
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
        try persistenceWriter(manifestURL, data)
    }

    private func withManifestLock<T>(_ operation: () throws -> T) throws -> T {
        try manifestLock.withExclusiveLock(operation)
    }

    private func persistRejections(_ log: [RejectedUpload]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: rejectionsURL, options: .atomic)
    }

    private static func loadRejections(at url: URL) -> [RejectedUpload] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RejectedUpload].self, from: data)) ?? []
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
        // O_CREAT without O_TRUNC keeps a stable inode so flock serializes
        // across processes. FileManager.createFile unlinks and recreates.
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
            // Never recreate the lock file: replacing the inode would drop the
            // `flock` a live staging copy is holding on the old one.
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
        let trimmed = droppingAudioExtension(title).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// A share title is text, not a path: "Call with A/B Growth" must survive, so
    /// the suffix is trimmed as a string rather than through `URL` components.
    /// Only known audio extensions go, keeping "Call with Dr. Smith" intact.
    private static let strippableExtensions: Set<String> = ["m4a", "caf", "wav", "mp3", "mp4", "aac", "aiff", "aif"]

    private static func droppingAudioExtension(_ title: String) -> String {
        guard let dot = title.lastIndex(of: "."),
              strippableExtensions.contains(title[title.index(after: dot)...].lowercased())
        else { return title }
        return String(title[title.startIndex..<dot])
    }

    private static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.date(from: text)
    }
}
