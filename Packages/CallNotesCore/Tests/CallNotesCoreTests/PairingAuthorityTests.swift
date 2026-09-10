import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PairingAuthorityTests {
    @Test func aPairedDeviceCanAuthorizeUntilItIsRevoked() async throws {
        let authority = PairingAuthority(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let ticket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )

        let pair = try await authority.pair(
            PairingRequest(code: ticket.code, deviceName: "Maya’s iPhone")
        )

        #expect(await authority.authorize(token: pair.token)?.id == pair.deviceID)

        try await authority.revoke(deviceID: pair.deviceID)

        #expect(await authority.authorize(token: pair.token) == nil)
    }

    @Test func pairingCodeIsSingleUseAndExpires() async throws {
        let authority = PairingAuthority(now: { Date(timeIntervalSince1970: 1_700_000_000) }, codeLifetime: 60)
        let ticket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        _ = try await authority.pair(PairingRequest(code: ticket.code, deviceName: "Maya’s iPhone"))

        await #expect(throws: PairingError.invalidCode) {
            try await authority.pair(PairingRequest(code: ticket.code, deviceName: "Second iPhone"))
        }

        let expiringAuthority = PairingAuthority(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            codeLifetime: -1
        )
        let expiryTicket = await expiringAuthority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )

        await #expect(throws: PairingError.expiredCode) {
            try await expiringAuthority.pair(PairingRequest(code: expiryTicket.code, deviceName: "Late iPhone"))
        }
    }

    @Test func certificateFingerprintComparisonRejectsAnotherCertificate() {
        let certificate = Data("mac certificate".utf8)
        let expected = CertificateFingerprint.sha256(of: certificate)

        #expect(CertificateFingerprint.matches(certificate, expected: expected.uppercased()))
        #expect(!CertificateFingerprint.matches(Data("other certificate".utf8), expected: expected))
    }

    #if os(macOS)
    @Test func tlsIdentityPersistsItsPinnedCertificate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = try MacTLSIdentity(storageDirectory: directory)
        let reopened = try MacTLSIdentity(storageDirectory: directory)
        #expect(created.certificateFingerprint == reopened.certificateFingerprint)
        #expect(!created.privateKeyPEM.isEmpty)
    }
    #endif
}
