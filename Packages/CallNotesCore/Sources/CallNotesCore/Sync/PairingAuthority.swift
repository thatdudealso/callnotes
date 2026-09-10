import CryptoKit
import Foundation

/// The public contents of the one-time QR pairing payload.
///
/// The certificate fingerprint is deliberately carried alongside the server
/// address. The iPhone must pin it before it sends the pairing code.
public struct PairingTicket: Codable, Sendable, Equatable {
    public var serverURL: URL
    public var code: String
    public var certificateFingerprint: String
    public var expiresAt: Date

    public init(serverURL: URL, code: String, certificateFingerprint: String, expiresAt: Date) {
        self.serverURL = serverURL
        self.code = code
        self.certificateFingerprint = certificateFingerprint
        self.expiresAt = expiresAt
    }
}

/// The request sent by a newly scanned iPhone to `POST /pair`.
public struct PairingRequest: Codable, Sendable, Equatable {
    public var code: String
    public var deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

/// A paired device. The authentication token is never included in this type.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public init(id: UUID, name: String, pairedAt: Date, lastSeenAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidCode
    case expiredCode
    case pairingRateLimited
    case invalidDeviceName
    case unknownDevice

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "That pairing code is no longer valid. Show a new QR code on your Mac."
        case .expiredCode: "That pairing code expired. Show a new QR code on your Mac."
        case .pairingRateLimited: "Too many pairing attempts. Try again shortly."
        case .invalidDeviceName: "Enter a name for this iPhone."
        case .unknownDevice: "That paired device no longer exists."
        }
    }
}

/// Owns pairing codes and revocable device tokens on the Mac.
///
/// Only SHA-256 digests of tokens are retained. This makes a device revocation
/// take effect at authorization time without retaining a reusable secret.
public actor PairingAuthority {
    private struct PendingCode: Sendable {
        var code: String
        var expiresAt: Date
    }

    private struct StoredDevice: Sendable {
        var device: PairedDevice
        var tokenDigest: String
    }

    private let now: @Sendable () -> Date
    private let codeLifetime: TimeInterval
    private let maximumAttempts: Int
    private var pendingCodes: [String: PendingCode] = [:]
    private var devices: [UUID: StoredDevice] = [:]
    private var failedAttempts: Int = 0

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        codeLifetime: TimeInterval = 120,
        maximumAttempts: Int = 5
    ) {
        self.now = now
        self.codeLifetime = codeLifetime
        self.maximumAttempts = maximumAttempts
    }

    public func issueTicket(serverURL: URL, certificateFingerprint: String) -> PairingTicket {
        let expiration = now().addingTimeInterval(codeLifetime)
        let code = Self.makeCode()
        pendingCodes[code] = PendingCode(code: code, expiresAt: expiration)
        return PairingTicket(
            serverURL: serverURL,
            code: code,
            certificateFingerprint: certificateFingerprint.lowercased(),
            expiresAt: expiration
        )
    }

    public func pair(_ request: PairingRequest) throws -> SyncDTO.PairResponse {
        let deviceName = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceName.isEmpty else { throw PairingError.invalidDeviceName }
        guard failedAttempts < maximumAttempts else { throw PairingError.pairingRateLimited }
        guard let pending = pendingCodes.removeValue(forKey: request.code) else {
            failedAttempts += 1
            throw PairingError.invalidCode
        }
        guard pending.expiresAt >= now() else { throw PairingError.expiredCode }

        failedAttempts = 0
        let device = PairedDevice(id: UUID(), name: deviceName, pairedAt: now())
        let token = Self.makeToken()
        devices[device.id] = StoredDevice(device: device, tokenDigest: Self.digest(token))
        return SyncDTO.PairResponse(deviceID: device.id, token: token)
    }

    /// Returns the device only while its token is valid and it has not been revoked.
    public func authorize(token: String) -> PairedDevice? {
        let tokenDigest = Self.digest(token)
        guard let (id, stored) = devices.first(where: { $0.value.tokenDigest == tokenDigest }),
              stored.device.revokedAt == nil
        else { return nil }
        var updated = stored.device
        updated.lastSeenAt = now()
        devices[id] = StoredDevice(device: updated, tokenDigest: stored.tokenDigest)
        return updated
    }

    public func revoke(deviceID: UUID) throws {
        guard var stored = devices[deviceID] else { throw PairingError.unknownDevice }
        stored.device.revokedAt = now()
        devices[deviceID] = stored
    }

    public func pairedDevices() -> [PairedDevice] {
        devices.values.map(\.device).sorted { $0.pairedAt > $1.pairedAt }
    }

    private static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
