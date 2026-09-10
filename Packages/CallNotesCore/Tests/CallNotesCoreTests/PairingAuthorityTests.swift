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

    @Test func pairedDevicesAndRevocationSurviveANewAuthority() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-paired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let authority = PairingAuthority(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            persistenceURL: url
        )
        let ticket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        let pair = try await authority.pair(PairingRequest(code: ticket.code, deviceName: "Maya’s iPhone"))

        let reloaded = PairingAuthority(
            now: { Date(timeIntervalSince1970: 1_700_000_100) },
            persistenceURL: url
        )
        #expect(await reloaded.authorize(token: pair.token)?.id == pair.deviceID)
        try await reloaded.revoke(deviceID: pair.deviceID)

        let afterRevoke = PairingAuthority(
            now: { Date(timeIntervalSince1970: 1_700_000_200) },
            persistenceURL: url
        )
        #expect(await afterRevoke.authorize(token: pair.token) == nil)
    }

    @Test func pairingRateLimitExpiresWithTheAttemptWindow() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = PairingAuthority(
            now: { clock.now },
            maximumAttempts: 2,
            attemptWindow: 60
        )
        await #expect(throws: PairingError.invalidCode) {
            try await authority.pair(PairingRequest(code: "000000", deviceName: "Maya’s iPhone"))
        }
        await #expect(throws: PairingError.invalidCode) {
            try await authority.pair(PairingRequest(code: "000001", deviceName: "Maya’s iPhone"))
        }
        await #expect(throws: PairingError.pairingRateLimited) {
            try await authority.pair(PairingRequest(code: "000002", deviceName: "Maya’s iPhone"))
        }

        clock.now = clock.now.addingTimeInterval(61)
        let ticket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        let pair = try await authority.pair(PairingRequest(code: ticket.code, deviceName: "Maya’s iPhone"))
        #expect(await authority.authorize(token: pair.token)?.id == pair.deviceID)
    }

    @Test func pairingTicketQRPayloadRoundTrips() throws {
        let ticket = PairingTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            code: "123456",
            certificateFingerprint: "aabbcc",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_120)
        )
        let decoded = try PairingTicket.fromQRPayload(ticket.qrPayload())
        #expect(decoded == ticket)
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

    @Test func pinnedSessionAcceptsItsMacAndRejectsAnotherCertificate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try MacTLSIdentity(storageDirectory: directory)
        let server = MacSyncServer(store: MemoryStore())
        let task = Task { try? await server.run(host: "127.0.0.1", identity: identity) }
        defer { task.cancel() }
        let url = try #require(URL(string: "https://127.0.0.1:\(SyncConstants.serverPort)/health"))
        let trusted = URLSession(configuration: .ephemeral, delegate: PinnedURLSessionDelegate(fingerprint: identity.certificateFingerprint), delegateQueue: nil)
        var response: URLResponse?
        for _ in 0..<20 {
            if let result = try? await trusted.data(from: url) {
                response = result.1
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let rejected = URLSession(configuration: .ephemeral, delegate: PinnedURLSessionDelegate(fingerprint: String(repeating: "0", count: 64)), delegateQueue: nil)
        let rejectedSucceeded: Bool
        do {
            _ = try await rejected.data(from: url)
            rejectedSucceeded = true
        } catch {
            rejectedSucceeded = false
        }
        #expect(!rejectedSucceeded)
    }
    #endif
}

private final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
