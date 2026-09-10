#if os(macOS)
import Crypto
import Foundation
import Security
import X509

/// Long-lived self-signed identity for the local Mac API. The fingerprint is
/// placed in the QR pairing payload and is the iPhone's sole trust anchor.
public struct MacTLSIdentity: Sendable {
    public let certificateDER: Data
    public let privateKeyPEM: String

    public var certificateFingerprint: String { CertificateFingerprint.sha256(of: certificateDER) }

    public init(storageDirectory: URL, commonName: String = "CallNotes Mac") throws {
        let certificateURL = storageDirectory.appendingPathComponent("sync-server.cer")
        let keyURL = storageDirectory.appendingPathComponent("sync-server.key")
        if let certificate = try? Data(contentsOf: certificateURL),
           let key = try? String(contentsOf: keyURL, encoding: .utf8)
        {
            certificateDER = certificate
            privateKeyPEM = key
            return
        }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName(commonName) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(bytes: Array(UUID().uuidString.utf8)),
            publicKey: key.publicKey,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 365 * 10),
            issuer: name,
            subject: name,
            extensions: Certificate.Extensions {},
            issuerPrivateKey: key
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        let der = SecCertificateCopyData(secCertificate) as Data
        let pem = try key.serializeAsPEM().pemString
        try der.write(to: certificateURL, options: .atomic)
        try pem.write(to: keyURL, atomically: true, encoding: .utf8)
        certificateDER = der
        privateKeyPEM = pem
    }
}
#endif
