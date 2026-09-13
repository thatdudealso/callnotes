import Foundation

public struct DiagnosticsSnapshot: Sendable, Equatable, Codable {
    public var createdAt: Date
    public var appVersion: String
    public var osVersion: String
    public var storeBackend: String
    public var engineDefault: String
    public var consentPolicy: String
    public var retention: String
    public var dualInstanceMode: String?
    public var health: [String: String]
    public var logLines: [DiagnosticEvent]
    public var exclusions: [String]

    public init(
        createdAt: Date = Date(),
        appVersion: String,
        osVersion: String,
        storeBackend: String,
        engineDefault: String,
        consentPolicy: String,
        retention: String,
        dualInstanceMode: String? = nil,
        health: [String: String],
        logLines: [DiagnosticEvent],
        exclusions: [String] = DiagnosticsBundle.exclusions
    ) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.storeBackend = storeBackend
        self.engineDefault = engineDefault
        self.consentPolicy = consentPolicy
        self.retention = retention
        self.dualInstanceMode = dualInstanceMode
        self.health = health
        self.logLines = logLines.filter(DiagnosticsBundle.isExportableLogEvent)
        self.exclusions = exclusions
    }
}

/// Exportable support bundle. It never copies call audio, transcript text,
/// notes bodies, API keys, device tokens, or database passwords.
public enum DiagnosticsBundle: Sendable {
    public static let exclusions = [
        "call audio files",
        "transcript text",
        "notes body text",
        "API keys",
        "device tokens",
        "database passwords",
        "pairing secrets",
    ]

    public static let snapshotFileName = "diagnostics.json"
    public static let exclusionsFileName = "EXCLUSIONS.txt"

    static func isExportableLogEvent(_ event: DiagnosticEvent) -> Bool {
        let transcriptFields: Set<String> = [
            "text", "start", "startsec", "end", "endsec", "channel", "clusterkey", "words",
        ]
        return event.metadata.keys.allSatisfy { !transcriptFields.contains($0.lowercased()) }
    }

    public static func export(_ snapshot: DiagnosticsSnapshot, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(snapshot)
        try json.write(to: directory.appendingPathComponent(snapshotFileName), options: .atomic)
        let exclusionText = """
            CallNotes diagnostics bundle
            This archive excludes:
            \(exclusions.map { "- \($0)" }.joined(separator: "\n"))

            Verified by DiagnosticsBundle.containsForbiddenContent on export.
            """
        try exclusionText.write(
            to: directory.appendingPathComponent(exclusionsFileName),
            atomically: true,
            encoding: .utf8
        )
        if let forbidden = containsForbiddenContent(in: directory) {
            try? FileManager.default.removeItem(at: directory)
            throw DiagnosticsBundleError.containsForbiddenContent(forbidden)
        }
        return directory
    }

    /// Returns a human-readable reason when a generated bundle includes
    /// something it must never ship. Used by tests and as an export gate.
    public static func containsForbiddenContent(in directory: URL) -> String? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let ext = item.pathExtension.lowercased()
            if ["caf", "m4a", "wav", "aiff", "aif", "aac", "mp3"].contains(ext) {
                return "audio file \(item.lastPathComponent)"
            }
            guard let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
            let lowered = text.lowercased()
            if lowered.contains("bearer ") || (lowered.contains("sk-") && !lowered.contains("<redacted>")) {
                return "credential in \(item.lastPathComponent)"
            }
        }
        return nil
    }
}

public enum DiagnosticsBundleError: Error, Equatable, Sendable {
    case containsForbiddenContent(String)
}
