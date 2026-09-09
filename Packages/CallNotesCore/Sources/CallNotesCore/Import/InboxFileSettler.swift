import Foundation

/// Waits out partial writes (AirDrop, iCloud download, Finder copy) by requiring
/// the file size to stay unchanged for `settleDuration`.
public actor InboxFileSettler {
    public var settleDuration: TimeInterval
    public var pollInterval: TimeInterval

    private var lastSize: [URL: Int] = [:]
    private var stableSince: [URL: Date] = [:]

    public init(settleDuration: TimeInterval = 1.5, pollInterval: TimeInterval = 0.2) {
        self.settleDuration = settleDuration
        self.pollInterval = pollInterval
    }

    /// Records the current size. Returns true once the size has been unchanged
    /// for `settleDuration`. A size change resets the clock.
    public func observe(_ url: URL, now: Date = Date(), fileManager: FileManager = .default) -> Bool {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        if lastSize[url] != size {
            lastSize[url] = size
            stableSince[url] = now
            return false
        }
        let started = stableSince[url] ?? now
        return now.timeIntervalSince(started) >= settleDuration && size >= 0
    }

    public func forget(_ url: URL) {
        lastSize[url] = nil
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
