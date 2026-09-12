import Foundation

/// Wire types shared by the Mac's Hummingbird server and the iOS client.
/// Endpoint handlers arrive in Phase 6.
public enum SyncDTO {
    public struct Mirror: Codable, Sendable {
        public var calls: [MirroredCall]
        public init(calls: [MirroredCall]) { self.calls = calls }
    }

    public struct MirroredCall: Codable, Sendable {
        public var id: UUID
        public var title: String
        public var summary: String
        public var startedAt: Date
        public var source: String
        public var status: String
        public var segments: [MirroredSegment]
        public var note: MirroredNote?
        public init(id: UUID, title: String, summary: String, startedAt: Date, source: String, status: String, segments: [MirroredSegment], note: MirroredNote?) {
            self.id = id; self.title = title; self.summary = summary; self.startedAt = startedAt; self.source = source; self.status = status; self.segments = segments; self.note = note
        }
    }

    public struct MirroredSegment: Codable, Sendable {
        public var id: String; public var speaker: String; public var text: String; public var startSec: Double
        public init(id: String, speaker: String, text: String, startSec: Double) { self.id = id; self.speaker = speaker; self.text = text; self.startSec = startSec }
    }

    public struct MirroredNote: Codable, Sendable {
        public var summary: String; public var decisions: [String]; public var actionItems: [String]
        public init(summary: String, decisions: [String], actionItems: [String]) { self.summary = summary; self.decisions = decisions; self.actionItems = actionItems }
    }
    /// `POST /pair` response: a long-lived, revocable device token.
    public struct PairResponse: Codable, Sendable {
        public var deviceID: UUID
        public var token: String

        public init(deviceID: UUID, token: String) {
            self.deviceID = deviceID
            self.token = token
        }
    }

    /// `POST /calls` multipart metadata part.
    public struct CallUpload: Codable, Sendable {
        public var source: CallSource
        public var startedAt: Date
        public var counterpartyName: String?

        public init(source: CallSource, startedAt: Date, counterpartyName: String? = nil) {
            self.source = source
            self.startedAt = startedAt
            self.counterpartyName = counterpartyName
        }
    }

    /// `GET /health` response body (plan section 15).
    public struct HealthReport: Codable, Sendable {
        public var checks: [String: Bool]

        public init(checks: [String: Bool]) {
            self.checks = checks
        }
    }
}

/// Both ends of the phone-to-Mac API. Hummingbird's default request context
/// encodes and decodes with `.iso8601`, so every client coder is built here
/// rather than per call site: a bare `JSONDecoder` reads `startedAt` as a
/// `Double` and fails on the string the server actually sends.
public enum SyncCoder {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Hummingbird renders a thrown `HTTPError` body as `{"error":{"message":...}}`.
/// The phone shows the sentence inside, not the envelope around it.
public enum SyncErrorBody {
    private struct Envelope: Decodable {
        struct Failure: Decodable { let message: String }
        let error: Failure
    }

    public static func message(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            let message = envelope.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}

/// The Mac API server's fixed port and Bonjour service type.
public enum SyncConstants {
    public static let serverPort = 47_800
    public static let bonjourServiceType = "_callnotes._tcp"
    public static let appGroupIdentifier = "group.com.thatdudealso.callnotes"
    public static let phoneUploadsDirectoryName = "PhoneUploads"
    public static let sharedAudioDirectoryName = "SharedAudio"
    public static let uploadRequestsDirectoryName = "UploadRequests"
    public static let recordingsDirectoryName = "Recordings"
}
