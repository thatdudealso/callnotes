import Foundation

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
    private var entries: [PendingUpload]

    public init(directory: URL) throws {
        self.directory = directory
        uploadsDirectory = directory.appendingPathComponent("uploads", isDirectory: true)
        manifestURL = directory.appendingPathComponent("pending-uploads.json")
        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        entries = try Self.loadManifest(at: manifestURL)
    }

    public func enqueue(audioAt sourceURL: URL, metadata: CallUploadMetadata) throws -> PendingUpload {
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

    public func pending(now: Date = Date()) -> [PendingUpload] {
        reload()
        return entries.filter { entry in
            guard FileManager.default.fileExists(atPath: entry.audioURL.path) else { return false }
            return entry.nextAttemptAt.map { $0 <= now } ?? true
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func markFailed(_ id: UUID, at date: Date = Date()) throws {
        reload()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw PendingUploadInboxError.unknownUpload
        }
        entries[index].retryCount += 1
        let delay = min(pow(2, Double(entries[index].retryCount)) * 15, 6 * 60 * 60)
        entries[index].nextAttemptAt = date.addingTimeInterval(delay)
        try persist()
    }

    /// A rejected token is not a transient failure: the job waits for the user
    /// to pair again rather than sitting out an exponential backoff.
    public func clearBackoff(_ id: UUID) throws {
        reload()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw PendingUploadInboxError.unknownUpload
        }
        entries[index].retryCount = 0
        entries[index].nextAttemptAt = nil
        try persist()
    }

    public func markCompleted(_ id: UUID) throws {
        reload()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw PendingUploadInboxError.unknownUpload
        }
        let entry = entries.remove(at: index)
        try? FileManager.default.removeItem(at: entry.audioURL)
        try persist()
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

    private static func loadManifest(at url: URL) throws -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingUpload].self, from: Data(contentsOf: url))
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
