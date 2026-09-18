import Foundation

/// Rolling on-device log used by the diagnostics bundle. Callers pass
/// structured events, never transcript text or secrets.
public struct DiagnosticEvent: Sendable, Equatable, Codable {
    public var at: Date
    public var category: String
    public var event: String
    public var metadata: [String: String]

    public init(at: Date = Date(), category: String, event: String, metadata: [String: String] = [:]) {
        self.at = at
        self.category = category
        self.event = event
        self.metadata = DiagnosticLog.redact(metadata)
    }
}

public enum DiagnosticLog: Sendable {
    public static let folderName = "logs"
    public static let fileName = "diagnostics.jsonl"
    public static let maxLines = 500

    private static let secretKeys: Set<String> = [
        "api_key", "apikey", "token", "password", "secret", "authorization",
        "bearer", "credential", "device_token", "pairing",
    ]

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func append(_ event: DiagnosticEvent, root: URL, fileManager: FileManager = .default) throws {
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(root: root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(event)
        line.append(contentsOf: "\n".utf8)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
        try trim(url: url, fileManager: fileManager)
    }

    public static func recentLines(root: URL, limit: Int = maxLines) throws -> [String] {
        let url = fileURL(root: root)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return Array(lines.suffix(limit))
    }

    public static func recentEvents(root: URL, limit: Int = maxLines) throws -> [DiagnosticEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try recentLines(root: root, limit: limit).compactMap { line in
            try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8))
        }
    }

    public static func redact(_ metadata: [String: String]) -> [String: String] {
        var redacted: [String: String] = [:]
        for (key, value) in metadata {
            if secretKeys.contains(key.lowercased()) || looksLikeSecret(value) {
                redacted[key] = "<redacted>"
            } else {
                redacted[key] = String(value.prefix(200))
            }
        }
        return redacted
    }

    public static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("bearer ") { return true }
        if lowered.contains("sk-") { return true }
        return false
    }

    private static func trim(url: URL, fileManager: FileManager) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return }
        let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
        try kept.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        _ = fileManager
    }
}
