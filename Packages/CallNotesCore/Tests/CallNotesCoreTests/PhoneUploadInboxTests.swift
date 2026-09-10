import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PhoneUploadInboxTests {
    @Test func noteTitlePrefillsCounterpartyAndStartTime() throws {
        let metadata = try #require(
            SharedRecordingTitleParser.parse("Call with Priya Shah, Sep 10, 2026 at 1:30 PM")
        )

        #expect(metadata.counterpartyName == "Priya Shah")
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: try #require(metadata.startedAt)
        )
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 10)
        #expect(components.hour == 13)
        #expect(components.minute == 30)
    }

    @Test func copiedUploadSurvivesANewProcessAndCanBeCompleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)

        let inbox = try PendingUploadInbox(directory: root.appendingPathComponent("shared", isDirectory: true))
        let job = try await inbox.enqueue(
            audioAt: source,
            metadata: CallUploadMetadata(
                source: .iphoneRecording,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                counterpartyName: "Priya"
            )
        )
        #expect(FileManager.default.fileExists(atPath: job.audioURL.path))

        let relaunchedInbox = try PendingUploadInbox(directory: root.appendingPathComponent("shared", isDirectory: true))
        #expect(await relaunchedInbox.pending().map(\.id) == [job.id])

        try await relaunchedInbox.markCompleted(job.id)
        #expect(await relaunchedInbox.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.audioURL.path))
    }

    #if os(macOS)
    @Test func reuploadingTheSameRecordingKeepsOneCallAndItsProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)
        let uploadID = UUID()
        let metadata = CallUploadMetadata(
            source: .iphoneRecording,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            counterpartyName: "Priya"
        )

        let first = try await server.accept(
            uploadID: uploadID,
            metadata: metadata,
            audio: Data("recording".utf8),
            fileExtension: "m4a"
        )
        #expect(first == .created)
        let stored = try #require(try await store.fetchCalls().first)
        #expect(stored.id == uploadID)
        #expect(FileManager.default.fileExists(atPath: stored.audioPath))

        var processed = stored
        processed.status = .notesReady
        try await store.upsertCall(processed)

        let second = try await server.accept(
            uploadID: uploadID,
            metadata: metadata,
            audio: Data("recording".utf8),
            fileExtension: "m4a"
        )
        #expect(second == .alreadyStored)
        let calls = try await store.fetchCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.status == .notesReady)
    }
    #endif
}
