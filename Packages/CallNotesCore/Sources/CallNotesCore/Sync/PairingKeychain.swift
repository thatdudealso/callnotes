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

/// This iPhone has no Mac credentials yet. Both the app and the Share Extension
/// hit it before anything is copied, and it is the first thing a new user sees,
/// so it names the step they are missing instead of a networking status.
public enum PairingCredentialError: Error, LocalizedError, Equatable {
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            "Pair this iPhone with your Mac first. Open CallNotes on your iPhone, go to Settings, and scan the QR code your Mac shows."
        }
    }
}

/// The app and the Share Extension read one another's pairing token, so the
/// access group has to be a value both processes compute identically. Both
/// entitle `$(AppIdentifierPrefix)group.com.thatdudealso.callnotes`, which only
/// exists with the team prefix the signer attached, so `kSecAttrAccessGroup` is
/// built from the group the keychain itself hands this process rather than from
/// a build setting that may not have expanded.
public enum PairingKeychain {
    public static let service = "com.thatdudealso.callnotes.phone-pairing"

    /// Only a resolution that actually reached the keychain is remembered. A
    /// process relaunched before first unlock cannot read its own probe item, and
    /// pinning that miss would leave the unentitled bare group in place until the
    /// app is killed, so an unresolved lookup is retried on the next use.
    public static var accessGroup: String { resolvedAccessGroup.value() }

    private static let resolvedAccessGroup = ResolvedAccessGroup(signedDefaultAccessGroup: signedDefaultAccessGroup)

    final class ResolvedAccessGroup: @unchecked Sendable {
        private let signedDefaultAccessGroup: @Sendable () -> String?
        private let lock = NSLock()
        private var resolved: String?

        init(signedDefaultAccessGroup: @escaping @Sendable () -> String?) {
            self.signedDefaultAccessGroup = signedDefaultAccessGroup
        }

        func value() -> String {
            lock.lock()
            defer { lock.unlock() }
            if let resolved { return resolved }
            guard let signed = signedDefaultAccessGroup() else { return SyncConstants.appGroupIdentifier }
            let group = sharedAccessGroup(defaultAccessGroup: signed)
            resolved = group
            return group
        }
    }

    static func sharedAccessGroup(defaultAccessGroup: String?) -> String {
        let shared = SyncConstants.appGroupIdentifier
        guard let defaultAccessGroup, !defaultAccessGroup.isEmpty else { return shared }
        if defaultAccessGroup == shared || defaultAccessGroup.hasSuffix(".\(shared)") { return defaultAccessGroup }
        guard let prefix = defaultAccessGroup.split(separator: ".").first, !prefix.isEmpty else { return shared }
        return "\(prefix).\(shared)"
    }

    /// The group the keychain assigns an item this process stores without asking
    /// for one: the first entitled `keychain-access-groups` entry, team prefix
    /// already applied. Its own service keeps it clear of `serviceQuery()`.
    private static func signedDefaultAccessGroup() -> String? {
        #if os(iOS)
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(service).access-group",
            kSecAttrAccount: "probe",
        ]
        var lookup = probe
        lookup[kSecReturnAttributes] = true
        var result: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound {
            var insert = probe
            insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            insert[kSecReturnAttributes] = true
            status = SecItemAdd(insert as CFDictionary, &result)
            if status == errSecDuplicateItem {
                status = SecItemCopyMatching(lookup as CFDictionary, &result)
            }
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
        #else
        return nil
        #endif
    }

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
