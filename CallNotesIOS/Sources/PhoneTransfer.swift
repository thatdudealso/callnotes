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

    static func uploadsDirectory() throws -> URL {
        try directory().appendingPathComponent("PhoneUploads", isDirectory: true)
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

enum PhoneSyncError: Error, LocalizedError {
    case unpaired

    var errorDescription: String? {
        switch self {
        case .unpaired: "This iPhone is no longer paired with your Mac. Scan the pairing QR code again."
        }
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
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }

    static func load() -> (PhonePairingConfiguration, String)? {
        guard let data = UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(PhonePairingConfiguration.self, from: data)
        else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: configuration.deviceID.uuidString,
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
        guard let (configuration, _) = load() else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: configuration.deviceID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults(suiteName: PhoneSharedContainer.appGroupIdentifier)?.removeObject(forKey: defaultsKey)
    }
}

enum PhonePairingCoordinator {
    static func pair(ticketPayload: String, deviceName: String) async throws -> PhonePairingConfiguration {
        let ticket = try PairingTicket.fromQRPayload(ticketPayload)
        guard ticket.expiresAt >= Date() else { throw PairingError.expiredCode }
        do {
            return try await pair(ticket: ticket, serverURL: ticket.serverURL, deviceName: deviceName)
        } catch let error as PairingError {
            throw error
        } catch let error as NSError where error.domain == "CallNotes.Pairing" {
            throw error
        } catch {
            let discovered = try await PhoneBonjourResolver.resolve(fingerprint: ticket.certificateFingerprint)
            return try await pair(ticket: ticket, serverURL: discovered, deviceName: deviceName)
        }
    }

    private static func pair(ticket: PairingTicket, serverURL: URL, deviceName: String) async throws -> PhonePairingConfiguration {
        let delegate = PinnedURLSessionDelegate(fingerprint: ticket.certificateFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
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
        } catch PhoneSyncError.unpaired {
            throw PhoneSyncError.unpaired
        } catch {
            var discovered = connection
            discovered.serverURL = try await PhoneBonjourResolver.resolve(fingerprint: connection.certificateFingerprint)
            return try await fetch(connection: discovered, token: token)
        }
    }

    private static func fetch(connection: PhonePairingConfiguration, token: String) async throws -> SyncDTO.Mirror {
        let delegate = PinnedURLSessionDelegate(fingerprint: connection.certificateFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: connection.serverURL.appendingPathComponent("mirror"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.cannotLoadFromNetwork) }
        guard http.statusCode != 401 else { throw PhoneSyncError.unpaired }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.cannotLoadFromNetwork) }
        return try JSONDecoder().decode(SyncDTO.Mirror.self, from: data)
    }
}

/// Finds the paired Mac when its QR hostname stops resolving. Every discovered
/// `_callnotes._tcp` candidate is tried until one serves the pinned certificate.
private final class PhoneBonjourResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var browser: NetServiceBrowser?
    private var service: NetService?
    private var pendingServices: [NetService] = []
    private var fingerprint = ""
    private var isFinished = false
    private var discoveryFinished = false

    private static let candidateTimeout: TimeInterval = 2
    private static let discoveryWindow: TimeInterval = 5

    static func resolve(fingerprint: String) async throws -> URL {
        try await PhoneBonjourResolver().resolveService(fingerprint: fingerprint)
    }

    /// `NetServiceBrowser` and `NetService` deliver their callbacks through the
    /// run loop they are scheduled on, and Swift's cooperative pool threads run
    /// none, so all discovery is driven from the main run loop.
    private func resolveService(fingerprint: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                self.fingerprint = fingerprint
            }
            DispatchQueue.main.async { [self] in
                let browser = NetServiceBrowser()
                let started = lock.withLock { () -> Bool in
                    guard !isFinished else { return false }
                    self.browser = browser
                    return true
                }
                guard started else { return }
                browser.delegate = self
                browser.schedule(in: .main, forMode: .common)
                browser.searchForServices(ofType: "\(SyncConstants.bonjourServiceType).", inDomain: "local.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoveryWindow) { [self] in
                endDiscovery()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        lock.withLock { pendingServices.append(service) }
        resolveNextService()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), sender.port > 0,
              let url = URL(string: "https://\(host):\(sender.port)")
        else {
            clearCurrentService()
            resolveNextService()
            return
        }
        let fingerprint = lock.withLock { self.fingerprint }
        Task { [self] in
            let delegate = PinnedURLSessionDelegate(fingerprint: fingerprint)
            do {
                let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.candidateTimeout
            configuration.timeoutIntervalForResource = Self.candidateTimeout
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (_, response) = try await session.data(from: url.appendingPathComponent("health"))
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.cannotConnectToHost) }
                finish(.success(url))
            } catch {
                clearCurrentService()
                resolveNextService()
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        clearCurrentService()
        resolveNextService()
    }

    private func clearCurrentService() {
        let current = lock.withLock { () -> NetService? in
            let current = service
            service = nil
            return current
        }
        guard let current else { return }
        let box = UncheckedBox(current)
        DispatchQueue.main.async { box.value.stop() }
    }

    private func resolveNextService() {
        let next = lock.withLock { () -> NetService? in
            guard !isFinished, service == nil, !pendingServices.isEmpty else { return nil }
            let next = pendingServices.removeFirst()
            service = next
            return next
        }
        guard let next else {
            finishIfExhausted()
            return
        }
        let box = UncheckedBox(next)
        DispatchQueue.main.async { [self] in
            box.value.delegate = self
            box.value.schedule(in: .main, forMode: .common)
            box.value.resolve(withTimeout: Self.candidateTimeout)
        }
    }

    /// The window bounds how long new candidates may appear. A candidate that is
    /// already queued still gets its own short resolve and health-check budget,
    /// so one asleep Mac cannot consume the whole sweep.
    private func endDiscovery() {
        let browser = lock.withLock { () -> NetServiceBrowser? in
            discoveryFinished = true
            let browser = self.browser
            self.browser = nil
            return browser
        }
        if let browser {
            let box = UncheckedBox(browser)
            DispatchQueue.main.async { box.value.stop() }
        }
        finishIfExhausted()
    }

    private func finishIfExhausted() {
        let exhausted = lock.withLock { discoveryFinished && service == nil && pendingServices.isEmpty }
        guard exhausted else { return }
        finish(.failure(URLError(.cannotFindHost)))
    }

    /// Resolves the continuation exactly once: the five-second timeout and a
    /// candidate's health check race, and each can arrive on a different thread.
    private func finish(_ result: Result<URL, Error>) {
        let (continuation, browser, service) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, NetServiceBrowser?, NetService?) in
            let taken = self.continuation
            self.continuation = nil
            isFinished = true
            let browser = self.browser
            self.browser = nil
            let service = self.service
            self.service = nil
            pendingServices.removeAll()
            return (taken, browser, service)
        }
        let box = UncheckedBox((browser, service))
        DispatchQueue.main.async {
            box.value.0?.stop()
            box.value.1?.stop()
        }
        continuation?.resume(with: result)
    }
}

/// Creates and re-creates the background tasks that `SessionUploadCoordinator`
/// asks for. It owns no durable state: the Core coordinator decides when a job
/// is completed, retried, or backed off.
final class PhoneUploadScheduler: SessionUploadTaskStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionProvider: (@Sendable () -> URLSession)?

    func attach(_ provider: @escaping @Sendable () -> URLSession) {
        lock.withLock { sessionProvider = provider }
    }

    func start(_ job: PendingUpload) async {
        guard let session = currentSession(), let (connection, token) = PhonePairingStore.load() else { return }
        try? Self.schedule(job, connection: connection, token: token, session: session)
    }

    func retry(_ job: PendingUpload) async -> Bool {
        guard let session = currentSession(),
              let (connection, token) = PhonePairingStore.load(),
              let endpoint = try? await PhoneBonjourResolver.resolve(fingerprint: connection.certificateFingerprint),
              endpoint != connection.serverURL,
              (try? PhonePairingStore.updateServerURL(endpoint)) != nil
        else { return false }
        var fallback = connection
        fallback.serverURL = endpoint
        do {
            try Self.schedule(job, connection: fallback, token: token, session: session)
            return true
        } catch {
            return false
        }
    }

    func authorizationRejected() async {
        PhonePairingStore.remove()
    }

    func discardRequestBody(for uploadID: UUID) async {
        guard let directory = try? PhoneSharedContainer.requestBodiesDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(uploadID.uuidString).appendingPathExtension("multipart"))
    }

    private func currentSession() -> URLSession? {
        lock.withLock { sessionProvider }?()
    }

    static func schedule(_ job: PendingUpload, connection: PhonePairingConfiguration, token: String, session: URLSession) throws {
        let body = try MultipartUploadBody.make(job: job, directory: PhoneSharedContainer.requestBodiesDirectory())
        var request = URLRequest(url: connection.serverURL.appendingPathComponent("calls").appendingPathComponent(job.id.uuidString))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: body.url)
        task.taskDescription = job.id.uuidString
        task.resume()
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Owns the app's two background sessions and hands every delegate callback to
/// the shared Core `SessionUploadCoordinator`, so transfers started by the
/// Share Extension settle through the same state machine after a relaunch.
final class BackgroundUploadCoordinator: @unchecked Sendable {
    static let shared = BackgroundUploadCoordinator()
    static let sessionIdentifier = "com.thatdudealso.callnotes.phone-upload"
    static let shareSessionIdentifier = SharedUploadSession.identifier

    private let scheduler = PhoneUploadScheduler()
    private let coordinator: SessionUploadCoordinator?
    private let delegate: SessionUploadDelegate?
    private let session: URLSession
    private let shareSession: URLSession

    private init() {
        let coordinator = try? SessionUploadCoordinator(
            directory: PhoneSharedContainer.uploadsDirectory(),
            starter: scheduler
        )
        self.coordinator = coordinator
        let delegate = coordinator.map { built in
            SessionUploadDelegate(coordinator: built, pinnedFingerprint: {
                PhonePairingStore.loadConfiguration()?.certificateFingerprint
            })
        }
        self.delegate = delegate
        session = SharedUploadSession.make(identifier: Self.sessionIdentifier, delegate: delegate)
        shareSession = SharedUploadSession.make(identifier: Self.shareSessionIdentifier, delegate: delegate)
        scheduler.attach { [unowned self] in self.session }
    }

    func handleBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        let box = UncheckedBox(completionHandler)
        guard let coordinator else {
            DispatchQueue.main.async { box.value() }
            return
        }
        coordinator.handleBackgroundEvents(identifier: identifier) {
            DispatchQueue.main.async { box.value() }
        }
    }

    func enqueue(audioAt url: URL, metadata: CallUploadMetadata) async throws {
        guard let coordinator else { throw CocoaError(.fileNoSuchFile) }
        try await coordinator.enqueue(audioAt: url, metadata: metadata)
    }

    func resume() async -> String {
        guard PhonePairingStore.load() != nil else {
            return "Pair with your Mac to send pending recordings."
        }
        guard let coordinator else { return "Shared storage for recordings is unavailable." }
        await coordinator.resume(skipping: await activeTaskIDs())
        return "Pending recordings will upload in the background."
    }

    private func activeTaskIDs() async -> Set<UUID> {
        let phoneTasks = await session.allTasks
        let shareTasks = await shareSession.allTasks
        return Set((phoneTasks + shareTasks).compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }
}

enum MultipartUploadBody {
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
