import Foundation

public protocol SessionUploadTaskStarting: Sendable {
    func start(uploadID: UUID) async
}

public actor SessionUploadCoordinator {
    private let inbox: PendingUploadInbox
    private let starter: any SessionUploadTaskStarting
    private var completionHandlers: [String: @Sendable () -> Void] = [:]

    public init(directory: URL, starter: any SessionUploadTaskStarting) throws {
        self.inbox = try PendingUploadInbox(directory: directory)
        self.starter = starter
    }

    public func resume() async {
        for job in await inbox.pending() {
            await starter.start(uploadID: job.id)
        }
    }

    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        completionHandlers[identifier] = completionHandler
    }

    public func taskCompleted(uploadID: UUID, error: Error?) async {
        if error == nil {
            try? await inbox.markCompleted(uploadID)
        } else {
            try? await inbox.markFailed(uploadID)
        }
    }

    public func finishBackgroundEvents(identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }
}
