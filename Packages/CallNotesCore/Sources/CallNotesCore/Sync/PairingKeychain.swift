import Foundation
import Security

public enum PairingKeychain {
    public static let service = "com.thatdudealso.callnotes.phone-pairing"

    public static func itemQuery(account: String) -> [CFString: Any]? {
        guard let accessGroup = accessGroup() else { return nil }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
        ]
    }

    public static func serviceQuery() -> [CFString: Any]? {
        guard let accessGroup = accessGroup() else { return nil }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
        ]
    }

    private static func accessGroup() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CallNotesKeychainAccessGroup") as? String
    }
}
