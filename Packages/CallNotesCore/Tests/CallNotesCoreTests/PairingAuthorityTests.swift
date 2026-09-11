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

    /// Revoke reports the failed write, but the lost phone must stop authorizing
    /// right away rather than waiting for a snapshot that never lands.
    @Test func revocationHoldsAndStillReportsAFailedPersist() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-paired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = PairingAuthority(persistenceURL: url)
        let ticket = await original.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        let pair = try await original.pair(PairingRequest(code: ticket.code, deviceName: "Maya’s iPhone"))
        let failing = PairingAuthority(
            persistenceURL: url,
            persistenceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        await #expect(throws: CocoaError.self) {
            try await failing.revoke(deviceID: pair.deviceID)
        }
        #expect(await failing.authorize(token: pair.token) == nil)
        #expect(await failing.pairedDevices().first(where: { $0.id == pair.deviceID })?.revokedAt != nil)

        let reloaded = PairingAuthority(persistenceURL: url)
        #expect(await reloaded.authorize(token: pair.token)?.id == pair.deviceID)
    }

    /// Every write serialises the whole device set, so a later pairing carries an
    /// earlier failed revocation to disk. The Devices pane must stop warning that
    /// the revoked phone comes back after a restart, because it no longer does.
    @Test func aLaterPairingMakesAnEarlierFailedRevocationDurable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-paired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writes = FlakyWriter()
        let authority = PairingAuthority(
            persistenceURL: url,
            persistenceWriter: { destination, data in try writes.write(data, to: destination) }
        )
        let firstTicket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        let lost = try await authority.pair(PairingRequest(code: firstTicket.code, deviceName: "Lost iPhone"))

        writes.fail = true
        await #expect(throws: CocoaError.self) {
            try await authority.revoke(deviceID: lost.deviceID)
        }
        #expect(await authority.unsavedRevocationIDs() == [lost.deviceID])

        writes.fail = false
        let secondTicket = await authority.issueTicket(
            serverURL: URL(string: "https://macbook.local:47800")!,
            certificateFingerprint: "AABBCC"
        )
        _ = try await authority.pair(PairingRequest(code: secondTicket.code, deviceName: "New iPhone"))

        #expect(await authority.unsavedRevocationIDs().isEmpty)
        let reloaded = PairingAuthority(persistenceURL: url)
        #expect(await reloaded.authorize(token: lost.token) == nil)
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

    /// Showing the Devices pane again issues a fresh code and sweeps the codes
    /// that expired unscanned, so they stop accumulating for the app's lifetime.
    @Test func issuingATicketSweepsCodesThatExpiredUnscanned() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = PairingAuthority(now: { clock.now }, codeLifetime: 120)
        let serverURL = URL(string: "https://macbook.local:47800")!

        let abandoned = await authority.issueTicket(serverURL: serverURL, certificateFingerprint: "AABBCC")
        clock.now = clock.now.addingTimeInterval(121)
        let replacement = await authority.issueTicket(serverURL: serverURL, certificateFingerprint: "AABBCC")

        // A retained expired code would still be found and reported as expired.
        await #expect(throws: PairingError.invalidCode) {
            try await authority.pair(PairingRequest(code: abandoned.code, deviceName: "Late iPhone"))
        }
        _ = try await authority.pair(PairingRequest(code: replacement.code, deviceName: "Maya’s iPhone"))
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

/// A snapshot volume that can be taken away and given back between writes.
private final class FlakyWriter: @unchecked Sendable {
    var fail = false

    func write(_ data: Data, to url: URL) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
    }
}
