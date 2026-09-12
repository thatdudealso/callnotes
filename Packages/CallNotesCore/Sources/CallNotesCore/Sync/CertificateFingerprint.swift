import CryptoKit
import Foundation

/// SHA-256 certificate fingerprints used by the QR pairing payload and iOS pin.
public enum CertificateFingerprint {
    public static func sha256(of certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ certificateDER: Data, expected: String) -> Bool {
        sha256(of: certificateDER).caseInsensitiveCompare(expected) == .orderedSame
    }
}
