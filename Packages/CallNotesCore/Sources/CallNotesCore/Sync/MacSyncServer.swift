#if os(macOS)
import Foundation
import Hummingbird
import HummingbirdTLS
import NIOSSL

extension SyncDTO.HealthReport: ResponseCodable {}
extension SyncDTO.PairResponse: ResponseCodable {}

/// Hummingbird API hosted by the Mac app. TLS is mandatory and the QR payload
/// contains the leaf certificate fingerprint for the phone to pin.
public actor MacSyncServer {
    private let pairing: PairingAuthority

    public init(pairing: PairingAuthority = PairingAuthority()) {
        self.pairing = pairing
    }

    public func pairingTicket(serverURL: URL, identity: MacTLSIdentity) async -> PairingTicket {
        await pairing.issueTicket(serverURL: serverURL, certificateFingerprint: identity.certificateFingerprint)
    }

    public func revoke(deviceID: UUID) async throws {
        try await pairing.revoke(deviceID: deviceID)
    }

    /// Runs until the containing app cancels the task. The app owns the task
    /// lifetime so it can hold a ProcessInfo activity while serving phones.
    public func run(host: String, identity: MacTLSIdentity) async throws {
        let router = Router()
        let pairing = self.pairing
        router.get("health") { _, _ in
            SyncDTO.HealthReport(checks: ["server": true])
        }
        router.post("pair") { request, context async throws -> SyncDTO.PairResponse in
            let payload = try await request.decode(as: PairingRequest.self, context: context)
            return try await pairing.pair(payload)
        }
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(key)
        )
        let app = Application(
            router: router,
            server: try .tls(.http1(), tlsConfiguration: tls),
            configuration: .init(address: .hostname(host, port: SyncConstants.serverPort))
        )
        try await app.runService()
    }
}
#endif
