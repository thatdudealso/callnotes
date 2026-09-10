import Foundation
import Testing

@testable import CallNotesCore

@Suite struct PhoneUploadInboxTests {
    @Test func noteTitlePrefillsCounterpartyAndStartTime() throws {
        let metadata = try #require(
            SharedRecordingTitleParser.parse("Call with Priya Shah, Sep 10, 2026 at 1:30 PM")
        )

        #expect(metadata.counterpartyName == "Priya Shah")
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
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

    @Test func failedRelaunchUploadRemainsQueuedForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let firstProcess = try PendingUploadInbox(directory: root.appendingPathComponent("shared", isDirectory: true))
        let job = try await firstProcess.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
        let relaunchedProcess = try PendingUploadInbox(directory: root.appendingPathComponent("shared", isDirectory: true))
        try await relaunchedProcess.markFailed(job.id, at: .distantPast)
        #expect(await relaunchedProcess.pending().map(\.id) == [job.id])
    }

    /// The relaunched app never calls the coordinator directly: a background
    /// session hands the terminal task event to the production delegate, which
    /// must settle the queue before the system's completion handler is released.
    @Test func relaunchedBackgroundSessionSettlesUploadBeforeReleasingTheSystemHandler() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.resume()
        #expect(harness.scheduler.log == ["start:\(job.id)"])

        let task = harness.uploadTask(for: job.id)
        await harness.coordinator.handleBackgroundEvents(identifier: harness.sessionIdentifier) {
            harness.scheduler.record("released-system-handler")
        }
        harness.delegate.urlSession(harness.session, task: task, didCompleteWithError: nil)
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.session)
        try await harness.waitForSystemHandler()

        #expect(harness.scheduler.log == [
            "start:\(job.id)",
            "discard:\(job.id)",
            "released-system-handler",
        ])
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).isEmpty)
    }

    @Test func relaunchedBackgroundSessionKeepsAFailedUploadQueued() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        let task = harness.uploadTask(for: job.id)
        await harness.coordinator.handleBackgroundEvents(identifier: harness.sessionIdentifier) {
            harness.scheduler.record("released-system-handler")
        }
        harness.delegate.urlSession(harness.session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.session)
        try await harness.waitForSystemHandler()

        #expect(harness.scheduler.log.last == "released-system-handler")
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [job.id])
    }

    @Test func rejectedUploadResponseKeepsTheRecordingQueued() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 500)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [job.id])
    }

    @Test func mirrorRemovalDeletesSegmentsAndNotesSoAReturningCallDoesNotCollide() throws {
        let callID = UUID()
        let store = FakeMirrorStore()
        let call = SyncDTO.MirroredCall(
            id: callID,
            title: "Call with Priya",
            summary: "Discussed the rollout",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "iphone_recording",
            status: "notes_ready",
            segments: [.init(id: "\(callID.uuidString)-0", speaker: "Priya", text: "Hello.", startSec: 0)],
            note: .init(summary: "Rollout", decisions: ["Ship"], actionItems: ["Email Priya"])
        )

        try MirrorReconciler.apply(SyncDTO.Mirror(calls: [call]), to: store)
        #expect(store.segmentIDs(callID: callID) == ["\(callID.uuidString)-0"])
        #expect(store.notes[callID] != nil)

        try MirrorReconciler.apply(SyncDTO.Mirror(calls: []), to: store)
        #expect(store.calls.isEmpty)
        #expect(store.segments.isEmpty)
        #expect(store.notes.isEmpty)

        try MirrorReconciler.apply(SyncDTO.Mirror(calls: [call]), to: store)
        #expect(store.calls.count == 1)
        #expect(store.segmentIDs(callID: callID) == ["\(callID.uuidString)-0"])
    }

    #if os(macOS)
    @Test func multipartUploadPreservesTrailingAudioCRLF() throws {
        let boundary = "CallNotes-test"
        let metadata = CallUploadMetadata(source: .iphoneRecording, counterpartyName: "Priya")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let audio = Data([0x01, 0x0D, 0x0A, 0x0D, 0x0A])
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        body.append(try encoder.encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let parsedResult = try MultipartCallUpload.parse(body, boundary: boundary)
        let parsed = try #require(parsedResult)
        #expect(parsed.audio == audio)
        #expect(parsed.metadata == metadata)
    }

    @Test func streamedMultipartUploadPreservesAudioWithoutBufferingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-streamed-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let boundary = "CallNotes-stream"
        let metadata = CallUploadMetadata(source: .iphoneRecording, counterpartyName: "Priya")
        let audio = Data(repeating: 0x7F, count: 128 * 1024) + Data([0x0D, 0x0A])
        let request = root.appendingPathComponent("request.multipart")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        body.append(try encoder.encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try body.write(to: request)

        let uploadResult = try MultipartCallUpload.parseFile(request, boundary: boundary, directory: root, uploadID: UUID())
        let upload = try #require(uploadResult)
        #expect(try Data(contentsOf: upload.audioURL) == audio)
        #expect(upload.metadata == metadata)
    }

    @Test func concurrentUploadAcceptanceRunsOneImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-upload-reservation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let counter = UploadCounter()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { callID, _, _ in
            await counter.record()
            try await Task.sleep(for: .milliseconds(100))
            guard var call = try await store.fetchCall(id: callID) else { return }
            call.status = .notesReady
            try await store.upsertCall(call)
        })
        let uploadID = UUID()
        let metadata = CallUploadMetadata(source: .iphoneRecording)
        async let first = server.accept(uploadID: uploadID, metadata: metadata, audio: Data("first".utf8), fileExtension: "m4a")
        async let second = server.accept(uploadID: uploadID, metadata: metadata, audio: Data("second".utf8), fileExtension: "m4a")
        let outcomes = try await [first, second]
        #expect(outcomes.filter { $0 == .created }.count == 1)
        #expect(outcomes.contains { $0 == .inProgress || $0 == .alreadyStored })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await counter.count == 1)
        #expect(try await store.fetchCalls().count == 1)
    }

    @Test func failedAcceptanceReleasesItsReservationForARetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let server = MacSyncServer(store: MemoryStore(), receivedUploadsDirectory: root)
        let uploadID = UUID()
        let metadata = CallUploadMetadata(source: .iphoneRecording)
        await #expect(throws: Error.self) {
            try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("audio".utf8), fileExtension: "m4a")
        }
        try FileManager.default.removeItem(at: root)
        let retry = try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("audio".utf8), fileExtension: "m4a")
        #expect(retry == .created)
    }

    @Test func unsafeAudioExtensionCannotOverwriteMetadataSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MacSyncServer(store: MemoryStore(), receivedUploadsDirectory: root)
        let uploadID = UUID()
        let audio = Data("audio bytes".utf8)
        let metadata = CallUploadMetadata(source: .iphoneRecording)
        let outcome = try await server.accept(uploadID: uploadID, metadata: metadata, audio: audio, fileExtension: "json")
        #expect(outcome == .created)
        let audioURL = root.appendingPathComponent("\(uploadID.uuidString).m4a")
        #expect(try Data(contentsOf: audioURL) == audio)
        #expect(CallUploadMetadata.loadSidecar(nextTo: audioURL) == metadata)
    }

    @Test func directEmptyAudioIsRejectedWithoutCreatingCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let uploadID = UUID()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)
        await #expect(throws: Error.self) {
            try await server.accept(uploadID: uploadID, metadata: .init(source: .iphoneRecording), audio: Data(), fileExtension: "m4a")
        }
        #expect(try await store.fetchCall(id: uploadID) == nil)
    }

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

    /// A 201 the phone already acknowledged must never strand a recording: when
    /// processing fails the staging audio is retained, and the next attempt at
    /// the same identifier resumes it in place instead of reporting it done.
    @Test func failedProcessingResumesOnTheNextAttemptWithoutDuplicatingTheCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let attempts = ProcessingAttempts()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { callID, _, _ in
            if await attempts.record() == 1 { throw ProcessingFailure() }
            guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
            call.status = .notesReady
            try await store.upsertCall(call)
        })
        let uploadID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CallUploadMetadata(source: .iphoneRecording, startedAt: startedAt, counterpartyName: "Priya")

        let created = try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("recording".utf8), fileExtension: "m4a")
        #expect(created == .created)

        var retry = MacSyncServer.UploadOutcome.alreadyStored
        for _ in 0..<200 where retry != .resumed {
            retry = try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("recording".utf8), fileExtension: "m4a")
            if retry != .resumed { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(retry == .resumed)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(uploadID.uuidString).m4a").path))

        var processed = try await store.fetchCall(id: uploadID)
        for _ in 0..<200 where processed?.status != .notesReady {
            try await Task.sleep(for: .milliseconds(10))
            processed = try await store.fetchCall(id: uploadID)
        }
        #expect(processed?.status == .notesReady)
        #expect(processed?.startedAt == startedAt)
        #expect(processed?.counterpartyName == "Priya")
        #expect(await attempts.count == 2)
        #expect(try await store.fetchCalls().count == 1)
    }

    @Test func importedPhoneUploadKeepsTheUploadedCallAndItsMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)
        let uploadID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CallUploadMetadata(
            source: .iphoneRecording,
            startedAt: startedAt,
            counterpartyName: "Priya"
        )
        let fixture = root.appendingPathComponent("fixture.wav")
        try ImportFixtureWriter.writeWAV(to: fixture, seconds: 0.3)
        let created = try await server.accept(
            uploadID: uploadID,
            metadata: metadata,
            audio: try Data(contentsOf: fixture),
            fileExtension: "wav"
        )
        #expect(created == .created)
        let audioURL = root.appendingPathComponent("\(uploadID.uuidString).wav")
        #expect(CallUploadMetadata.loadSidecar(nextTo: audioURL) == metadata)

        let pipeline = ImportPipeline(
            store: store,
            spine: FileTranscriptionSpine(
                speech: ScriptedPCMTranscriber(
                    near: [RawSegment(start: 0, end: 0.2, text: "Hello.", channel: .mixed)],
                    far: []
                ),
                diarizer: ScriptedDiarizer(clusters: []),
                store: store
            ),
            duplicates: InboxDuplicateIndex(),
            audioRoot: root.appendingPathComponent("audio", isDirectory: true)
        )
        let processed = try await pipeline.`import`(
            audioURL,
            engine: .appleSpeech,
            source: metadata.source,
            counterpartyName: metadata.counterpartyName,
            startedAt: metadata.startedAt,
            job: ImportJob(fileName: audioURL.lastPathComponent, sourceURL: audioURL, callID: uploadID)
        )
        let calls = try await store.fetchCalls()
        #expect(calls.count == 1)
        #expect(processed.call.id == uploadID)
        #expect(processed.call.source == .iphoneRecording)
        #expect(processed.call.counterpartyName == "Priya")
        #expect(processed.call.startedAt == startedAt)
    }
    #endif
}

private actor UploadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct ProcessingFailure: Error {}

private actor ProcessingAttempts {
    private(set) var count = 0
    func record() -> Int {
        count += 1
        return count
    }
}

/// Records the coordinator's calls in order so a test can assert that the
/// queue is settled before the background completion handler is released.
private final class RecordingScheduler: SessionUploadTaskStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var log: [String] { lock.withLock { events } }
    func record(_ event: String) { lock.withLock { events.append(event) } }
    func start(_ job: PendingUpload) async { record("start:\(job.id)") }
    func discardRequestBody(for uploadID: UUID) async { record("discard:\(uploadID)") }
}

/// A relaunched app: a real background `URLSession` wired to the production
/// `SessionUploadDelegate`, over an inbox a previous process already filled.
private struct RelaunchHarness {
    let root: URL
    let inboxDirectory: URL
    let sessionIdentifier: String
    let scheduler = RecordingScheduler()
    let coordinator: SessionUploadCoordinator
    let delegate: SessionUploadDelegate
    let session: URLSession

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("callnotes-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inboxDirectory = root.appendingPathComponent("shared", isDirectory: true)
        sessionIdentifier = "callnotes.test.upload.\(UUID().uuidString)"
        coordinator = try SessionUploadCoordinator(directory: inboxDirectory, starter: scheduler)
        delegate = SessionUploadDelegate(coordinator: coordinator, pinnedFingerprint: { nil })
        session = SharedUploadSession.make(identifier: sessionIdentifier, appGroupIdentifier: "", delegate: delegate)
    }

    func enqueueRecording() async throws -> PendingUpload {
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let sharingProcess = try PendingUploadInbox(directory: inboxDirectory)
        return try await sharingProcess.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
    }

    func uploadTask(for uploadID: UUID) -> URLSessionTask {
        let body = root.appendingPathComponent("\(uploadID.uuidString).multipart")
        try? Data("body".utf8).write(to: body)
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(SyncConstants.serverPort)/calls/\(uploadID.uuidString)")!)
        request.httpMethod = "POST"
        let task = session.uploadTask(with: request, fromFile: body)
        task.taskDescription = uploadID.uuidString
        return task
    }

    func waitForSystemHandler() async throws {
        for _ in 0..<200 where !scheduler.log.contains("released-system-handler") {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FakeMirrorStore: MirrorWriting {
    private(set) var calls: [UUID: SyncDTO.MirroredCall] = [:]
    private(set) var segments: [String: UUID] = [:]
    private(set) var notes: [UUID: SyncDTO.MirroredNote] = [:]

    struct DuplicateSegmentID: Error { var id: String }

    func segmentIDs(callID: UUID) -> [String] {
        segments.filter { $0.value == callID }.keys.sorted()
    }

    func localCallIDs() throws -> [UUID] { Array(calls.keys) }
    func removeSegments(callID: UUID) throws { segments = segments.filter { $0.value != callID } }
    func removeNote(callID: UUID) throws { notes[callID] = nil }
    func removeCall(id: UUID) throws { calls[id] = nil }
    func upsertCall(_ call: SyncDTO.MirroredCall) throws { calls[call.id] = call }

    func insertSegments(_ inserted: [SyncDTO.MirroredSegment], callID: UUID) throws {
        for segment in inserted {
            guard segments[segment.id] == nil else { throw DuplicateSegmentID(id: segment.id) }
            segments[segment.id] = callID
        }
    }

    func insertNote(_ note: SyncDTO.MirroredNote, callID: UUID) throws { notes[callID] = note }
    func commit() throws {}
}
