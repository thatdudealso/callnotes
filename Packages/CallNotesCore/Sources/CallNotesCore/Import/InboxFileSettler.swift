import Foundation

/// Waits out partial writes (AirDrop, iCloud download, Finder copy) by requiring
/// the file size to stay unchanged for `settleDuration`.
public actor InboxFileSettler {
    public var settleDuration: TimeInterval
    public var pollInterval: TimeInterval

    private struct FileState: Equatable {
        var size: Int
        var modificationDate: Date?
    }

    private var lastState: [URL: FileState] = [:]
    private var stableSince: [URL: Date] = [:]

    public init(settleDuration: TimeInterval = 1.5, pollInterval: TimeInterval = 0.2) {
        self.settleDuration = settleDuration
        self.pollInterval = pollInterval
    }

    /// Records the current size. Returns true once the size has been unchanged
    /// for `settleDuration`. A size change resets the clock.
    public func observe(_ url: URL, now: Date = Date(), fileManager: FileManager = .default) -> Bool {
        observeState(url, now: now, fileManager: fileManager).isSettled
    }

    func observeState(
        _ url: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> (isSettled: Bool, didChange: Bool) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let state = FileState(
            size: attributes?[.size] as? Int ?? -1,
            modificationDate: attributes?[.modificationDate] as? Date
        )
        if lastState[url] != state {
            lastState[url] = state
            stableSince[url] = now
            return (false, true)
        }
        let started = stableSince[url] ?? now
        return (now.timeIntervalSince(started) >= settleDuration && state.size >= 0, false)
    }

    public func forget(_ url: URL) {
        lastState[url] = nil
        stableSince[url] = nil
    }

    public func waitUntilSettled(
        _ url: URL,
        timeout: TimeInterval = 30,
        fileManager: FileManager = .default
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        _ = observe(url, now: Date(), fileManager: fileManager)
        while Date() < deadline {
            if observe(url, now: Date(), fileManager: fileManager) { return }
            try await Task.sleep(for: .seconds(pollInterval))
            try Task.checkCancellation()
        }
        throw FileImportError.timeout
    }
}
