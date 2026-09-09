#if os(macOS)
import CoreServices
#endif
import Foundation

/// Lists importable audio in an inbox directory. Used on launch (files dropped
/// while the app was quit) and as a poll fallback beside FSEvents.
public struct InboxDirectoryScanner: Sendable {
    public init() {}

    public func candidates(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { InboxCandidate.isImportable($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Watches an inbox folder: scan existing files, settle partial writes, skip
/// duplicates, and (on macOS) subscribe to FSEvents for live drops.
public final class InboxWatcher: @unchecked Sendable {
    public let directory: URL
    public var sourceForDirectory: CallSource
    public var onSettled: (@Sendable (URL) -> Void)?
    public var settler: InboxFileSettler
    public var scanner: InboxDirectoryScanner
    public var pollInterval: TimeInterval

    private var pollTask: Task<Void, Never>?
    private var announced: Set<URL> = []
    private let lock = NSLock()
#if os(macOS)
    private var eventStream: FSEventStreamRef?
#endif

    public init(
        directory: URL,
        sourceForDirectory: CallSource = .fileImport,
        settler: InboxFileSettler = InboxFileSettler(),
        scanner: InboxDirectoryScanner = InboxDirectoryScanner(),
        pollInterval: TimeInterval = 2
    ) {
        self.directory = directory
        self.sourceForDirectory = sourceForDirectory
        self.settler = settler
        self.scanner = scanner
        self.pollInterval = pollInterval
    }

    public func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        startPolling()
#if os(macOS)
        startFSEvents()
#endif
        Task { await scanNow() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
#if os(macOS)
        stopFSEvents()
#endif
    }

    @discardableResult
    public func scanNow() async -> [URL] {
        var ready: [URL] = []
        for url in scanner.candidates(in: directory) {
            if await settler.observe(url) {
                if remember(url) {
                    ready.append(url)
                    onSettled?(url)
                }
            }
        }
        return ready
    }

    private func remember(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return announced.insert(url).inserted
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.scanNow()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

#if os(macOS)
    private func startFSEvents() {
        stopFSEvents()
        let path = directory.path as CFString
        let paths = [path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<InboxWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            _ = count
            Task { await watcher.scanNow() }
            _ = paths
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "callnotes.inbox.fsevents"))
        FSEventStreamStart(stream)
    }

    private func stopFSEvents() {
        guard let eventStream else { return }
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)
        self.eventStream = nil
    }
#endif
}
