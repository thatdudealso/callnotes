import CallNotesCore
import CryptoKit
import Foundation
import Security
import UIKit

enum PhoneSharedContainer {
    static let appGroupIdentifier = "group.com.thatdudealso.callnotes"

    static func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func inbox() throws -> PendingUploadInbox {
        try PendingUploadInbox(directory: directory().appendingPathComponent("PhoneUploads", isDirectory: true))
    }

    static func recordingsDirectory() throws -> URL {
        let url = try directory().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func requestBodiesDirectory() throws -> URL {
        let url = try directory().appendingPathComponent("UploadRequests", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct PhonePairingConfiguration: Codable, Sendable {
    var serverURL: URL
    var deviceID: UUID
    var certificateFingerprint: String
}

enum PhonePairingStore {
    private static let defaultsKey = "paired_mac"
    private static let keychainService = "com.thatdudealso.callnotes.phone-pairing"

    static func save(_ configuration: PhonePairingConfiguration, token: String) throws {
        let defaults = UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)
        defaults?.set(try JSONEncoder().encode(configuration), forKey: defaultsKey)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: configuration.deviceID.uuidString,
            kSecAttrAccessGroup: try sharedAccessGroup(),
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }

    static func load() -> (PhonePairingConfiguration, String)? {
        guard let data = UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(PhonePairingConfiguration.self, from: data),
              let accessGroup = try? sharedAccessGroup()
        else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: configuration.deviceID.uuidString,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let tokenData = result as? Data,
              let token = String(data: tokenData, encoding: .utf8)
        else { return nil }
        return (configuration, token)
    }

    static func loadConfiguration() -> PhonePairingConfiguration? {
        guard let data = UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(PhonePairingConfiguration.self, from: data)
        else { return nil }
        return configuration
    }

    static func updateServerURL(_ serverURL: URL) throws {
        guard var configuration = loadConfiguration() else { throw CocoaError(.fileNoSuchFile) }
        configuration.serverURL = serverURL
        UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.set(try JSONEncoder().encode(configuration), forKey: defaultsKey)
    }

    static func remove() {
        guard let (configuration, _)= load(), let accessGroup = try? sharedAccessGroup() else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: configuration.deviceID.uuidString,
            kSecAttrAccessGroup: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.removeObject(forKey: defaultsKey)
    }

    private static func sharedAccessGroup() throws -> String {
        let task = SecTaskCreateFromSelf(nil)
        guard let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
              let group = groups.first(where: { $0.hasSuffix(".com.thatdudealso.callnotes.shared") })
        else { throw CocoaError(.fileNoSuchFile) }
        return group
    }
}

enum PhonePairingCoordinator {
    static func pair(ticketPayload: String, deviceName: String) async throws -> PhonePairingConfiguration {
        let ticket = try PairingTicket.fromQRPayload(ticketPayload)
        guard ticket.expiresAt >= Date() else { throw PairingError.expiredCode }
        do {
            return try await pair(ticket: ticket, serverURL: ticket.serverURL, deviceName: deviceName)
        } catch {
            let discovered = try await PhoneBonjourResolver.resolve(fingerprint: ticket.certificateFingerprint)
            return try await pair(ticket: ticket, serverURL: discovered, deviceName: deviceName)
        }
    }

    private static func pair(ticket: PairingTicket, serverURL: URL, deviceName: String) async throws -> PhonePairingConfiguration {
        let delegate = PinnedURLSessionDelegate(fingerprint: ticket.certificateFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: serverURL.appendingPathComponent("pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingRequest(code: ticket.code, deviceName: deviceName))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw NSError(domain: "CallNotes.Pairing", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Could not pair with this Mac."])
        }
        let paired = try JSONDecoder().decode(SyncDTO.PairResponse.self, from: data)
        let configuration = PhonePairingConfiguration(
            serverURL: serverURL,
            deviceID: paired.deviceID,
            certificateFingerprint: ticket.certificateFingerprint
        )
        try PhonePairingStore.save(configuration, token: paired.token)
        return configuration
    }
}

enum PhoneMirrorCoordinator {
    static func fetch() async throws -> SyncDTO.Mirror {
        guard let (connection, token) = PhonePairingStore.load() else { throw URLError(.userAuthenticationRequired) }
        do {
            return try await fetch(connection: connection, token: token)
        } catch {
            var discovered = connection
            discovered.serverURL = try await PhoneBonjourResolver.resolve(fingerprint: connection.certificateFingerprint)
            return try await fetch(connection: discovered, token: token)
        }
    }

    private static func fetch(connection: PhonePairingConfiguration, token: String) async throws -> SyncDTO.Mirror {
        let delegate = PinnedURLSessionDelegate(fingerprint: connection.certificateFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: connection.serverURL.appendingPathComponent("mirror"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.cannotLoadFromNetwork) }
        return try JSONDecoder().decode(SyncDTO.Mirror.self, from: data)
    }
}

private final class PhoneBonjourResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var browser: NetServiceBrowser?
    private var service: NetService?
    private var pendingServices: [NetService] = []
    private var fingerprint = ""

    static func resolve(fingerprint: String) async throws -> URL {
        try await PhoneBonjourResolver().resolveService(fingerprint: fingerprint)
    }

    private func resolveService(fingerprint: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.fingerprint = fingerprint
            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "\(SyncConstants.bonjourServiceType).", inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finish(.failure(URLError(.cannotFindHost)))
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pendingServices.append(service)
        resolveNextService()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), sender.port > 0,
              let url = URL(string: "https://\(host):\(sender.port)")
        else {
            service = nil
            resolveNextService()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let delegate = PinnedURLSessionDelegate(fingerprint: self.fingerprint)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            do {
                let (_, response) = try await session.data(from: url.appendingPathComponent("health"))
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.cannotConnectToHost) }
                self.finish(.success(url))
            } catch {
                self.service = nil
                self.resolveNextService()
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        service = nil
        resolveNextService()
    }

    private func resolveNextService() {
        guard service == nil else { return }
        guard !pendingServices.isEmpty else { return }
        let next = pendingServices.removeFirst()
        service = next
        next.delegate = self
        next.resolve(withTimeout: 5)
    }

    private func finish(_ result: Result<URL, Error>) {
        browser?.stop()
        browser = nil
        service?.stop()
        service = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Pins the leaf certificate supplied by the Mac pairing QR code. No CA exception is made.
final class PinnedURLSessionDelegate: NSObject, URLSessionDelegate {
    private let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard CertificateFingerprint.matches(der, expected: fingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class BackgroundUploadCoordinator: NSObject, @unchecked Sendable, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = BackgroundUploadCoordinator()
    private static let sessionIdentifier = "com.thatdudealso.callnotes.phone-upload"
    private static let shareSessionIdentifier = "com.thatdudealso.callnotes.share-upload"
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private lazy var shareSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.shareSessionIdentifier)
        configuration.sharedContainerIdentifier = PhoneSharedContainer.appGroupIdentifier
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let configuration = PhonePairingStore.loadConfiguration()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        PinnedURLSessionDelegate(fingerprint: configuration.certificateFingerprint)
            .urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func handleBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completionHandler
        if identifier == Self.sessionIdentifier { _ = session }
        if identifier == Self.shareSessionIdentifier { _ = shareSession }
    }

    func resume() async -> String {
        guard let (connection, token) = PhonePairingStore.load() else {
            return "Pair with your Mac to send pending recordings."
        }
        do {
            let inbox = try PhoneSharedContainer.inbox()
            let activeIDs = await activeTaskIDs()
            for job in await inbox.pending() where !activeIDs.contains(job.id) {
                try schedule(job, connection: connection, token: token, session: session)
            }
            return "Pending recordings will upload in the background."
        } catch { return error.localizedDescription }
    }

    private func schedule(_ job: PendingUpload, connection: PhonePairingConfiguration, token: String, session: URLSession) throws {
        let body = try MultipartUploadBody.make(job: job, directory: PhoneSharedContainer.requestBodiesDirectory())
        var request = URLRequest(url: connection.serverURL.appendingPathComponent("calls").appendingPathComponent(job.id.uuidString))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: body.url)
        task.taskDescription = job.id.uuidString
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let identifier = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task {
            guard let inbox = try? PhoneSharedContainer.inbox() else { return }
            if error == nil, let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                try? await inbox.markCompleted(identifier)
                Self.discardRequestBody(for: identifier)
            } else {
                if let job = await inbox.pending().first(where: { $0.id == identifier }),
                   let (connection, token) = PhonePairingStore.load(),
                   let endpoint = try? await PhoneBonjourResolver.resolve(fingerprint: connection.certificateFingerprint)
                {
                    var fallback = connection
                    fallback.serverURL = endpoint
                    if (try? PhonePairingStore.updateServerURL(endpoint)) != nil,
                       (try? self.schedule(job, connection: fallback, token: token, session: session)) != nil
                    {
                        return
                    }
                }
                try? await inbox.markFailed(identifier)
                Self.discardRequestBody(for: identifier)
            }
        }
    }

    private static func discardRequestBody(for identifier: UUID) {
        guard let directory = try? PhoneSharedContainer.requestBodiesDirectory() else { return }
        let body = directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("multipart")
        try? FileManager.default.removeItem(at: body)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let completionHandler = backgroundCompletionHandlers.removeValue(forKey: identifier)
        else { return }
        DispatchQueue.main.async(execute: completionHandler)
    }

    private func activeTaskIDs() async -> Set<UUID> {
        let phoneTasks = await session.allTasks
        let shareTasks = await shareSession.allTasks
        return Set((phoneTasks + shareTasks).compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }
}

private enum MultipartUploadBody {
    struct Body { var url: URL; var contentType: String }

    static func make(job: PendingUpload, directory: URL) throws -> Body {
        let boundary = "CallNotes-\(UUID().uuidString)"
        let url = directory.appendingPathComponent(job.id.uuidString).appendingPathExtension("multipart")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.write(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        try output.write(contentsOf: encoder.encode(job.metadata))
        try output.write(contentsOf: "\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(job.audioURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        let input = try FileHandle(forReadingFrom: job.audioURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        try output.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return Body(url: url, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
