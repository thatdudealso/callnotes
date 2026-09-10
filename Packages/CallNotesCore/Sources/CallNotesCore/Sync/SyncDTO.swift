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

/// The Mac API server's fixed port and Bonjour service type.
public enum SyncConstants {
    public static let serverPort = 47_800
    public static let bonjourServiceType = "_callnotes._tcp"
    public static let appGroupIdentifier = "group.com.thatdudealso.callnotes"
}
