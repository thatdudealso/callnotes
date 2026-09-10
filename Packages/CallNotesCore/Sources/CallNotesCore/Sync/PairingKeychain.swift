import Foundation
import Security

/// Why the pairing token could not be read or written. The access group is
/// named in every message: an entitlement mismatch is the one failure a user
/// cannot diagnose from "The file couldn't be saved."
public enum PairingKeychainError: Error, LocalizedError, Equatable {
    case operationFailed(status: OSStatus, accessGroup: String)

    public var errorDescription: String? {
        switch self {
        case let .operationFailed(status, accessGroup):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not use the shared keychain group \(accessGroup): \(detail) (OSStatus \(status))."
        }
    }
}

/// The app and the Share Extension read one another's pairing token, so the
/// access group has to be a value both processes compute identically. It is the
/// App Group identifier, which iOS admits as a keychain access group verbatim,
/// so nothing depends on `$(AppIdentifierPrefix)` expanding at build time or on
/// two targets agreeing about an Info.plist key.
public enum PairingKeychain {
    public static let service = "com.thatdudealso.callnotes.phone-pairing"
    public static let accessGroup = SyncConstants.appGroupIdentifier

    public static func itemQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
        ]
    }

    public static func serviceQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
        ]
    }

    public static func failure(_ status: OSStatus) -> PairingKeychainError {
        .operationFailed(status: status, accessGroup: accessGroup)
    }
}
