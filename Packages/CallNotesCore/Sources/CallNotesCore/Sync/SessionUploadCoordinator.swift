import Foundation

/// Schedules the platform transfer for one queued upload. The coordinator owns
/// every durable state transition, so a starter only creates and re-creates
/// background tasks.
public protocol SessionUploadTaskStarting: Sendable {
    func start(_ job: PendingUpload) async
    /// Returns `true` when the job was handed to a fresh task, which keeps it
    /// queued instead of being backed off as a failure.
    func retry(_ job: PendingUpload) async -> Bool
    func discardRequestBody(for uploadID: UUID) async
}

public extension SessionUploadTaskStarting {
    func retry(_ job: PendingUpload) async -> Bool { false }
    func discardRequestBody(for uploadID: UUID) async {}
}

/// The single upload state machine shared by the iOS app and its Share
/// Extension. Both processes drive it through `SessionUploadDelegate`, so a
/// transfer that finishes while the app is dead is settled the same way as one
/// that finishes in the foreground.
public actor SessionUploadCoordinator {
    private let inbox: PendingUploadInbox
    private let starter: any SessionUploadTaskStarting
    private var completionHandlers: [String: @Sendable () -> Void] = [:]

    public init(directory: URL, starter: any SessionUploadTaskStarting) throws {
        self.inbox = try PendingUploadInbox(directory: directory)
        self.starter = starter
    }

    /// Copies the audio into the App Group queue before starting its transfer,
    /// so the job outlives the process that shared it.
    @discardableResult
    public func enqueue(audioAt sourceURL: URL, metadata: CallUploadMetadata) async throws -> PendingUpload {
        let job = try await inbox.enqueue(audioAt: sourceURL, metadata: metadata)
        await starter.start(job)
        return job
    }

    public func resume(skipping active: Set<UUID> = []) async {
        for job in await inbox.pending() where !active.contains(job.id) {
            await starter.start(job)
        }
    }

    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        completionHandlers[identifier] = completionHandler
    }

    public func taskCompleted(uploadID: UUID, error: Error?, statusCode: Int? = nil) async {
        let succeeded = error == nil && (statusCode.map { (200..<300).contains($0) } ?? true)
        if succeeded {
            try? await inbox.markCompleted(uploadID)
            await starter.discardRequestBody(for: uploadID)
            return
        }
        if let job = await inbox.pending(now: .distantFuture).first(where: { $0.id == uploadID }),
           await starter.retry(job) {
            return
        }
        try? await inbox.markFailed(uploadID)
        await starter.discardRequestBody(for: uploadID)
    }

    public func finishBackgroundEvents(identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }
}

/// Production `URLSession` delegate for every CallNotes upload session. It
/// records each terminal task event before returning, so
/// `urlSessionDidFinishEvents` can drain them and only then release the
/// system's relaunch completion handler.
public final class SessionUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let coordinator: SessionUploadCoordinator
    private let pinnedFingerprint: @Sendable () -> String?
    private let lock = NSLock()
    private var transitions: [Task<Void, Never>] = []

    public init(coordinator: SessionUploadCoordinator, pinnedFingerprint: @escaping @Sendable () -> String?) {
        self.coordinator = coordinator
        self.pinnedFingerprint = pinnedFingerprint
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let uploadID = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let coordinator = self.coordinator
        let transition = Task {
            await coordinator.taskCompleted(uploadID: uploadID, error: error, statusCode: statusCode)
        }
        lock.withLock { transitions.append(transition) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        let pending = lock.withLock {
            let snapshot = transitions
            transitions.removeAll()
            return snapshot
        }
        let coordinator = self.coordinator
        Task {
            for transition in pending { await transition.value }
            await coordinator.finishBackgroundEvents(identifier: identifier)
        }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let fingerprint = pinnedFingerprint()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        PinnedURLSessionDelegate(fingerprint: fingerprint)
            .urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}

/// The background `URLSession` configuration shared by the iOS app and its
/// Share Extension. Both processes must agree on the identifier so the app can
/// reattach to a transfer the extension started and settle it through
/// `SessionUploadCoordinator`.
public enum SharedUploadSession {
    public static let identifier = "com.thatdudealso.callnotes.share-upload"

    public static func make(identifier: String, appGroupIdentifier: String = "group.com.thatdudealso.callnotes", delegate: SessionUploadDelegate?) -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = appGroupIdentifier
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}
