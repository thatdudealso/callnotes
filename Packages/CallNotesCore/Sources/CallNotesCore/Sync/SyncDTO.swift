import Foundation

/// Wire types shared by the Mac's Hummingbird server and the iOS client.
/// Endpoint handlers arrive in Phase 6.
public enum SyncDTO {
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
}
