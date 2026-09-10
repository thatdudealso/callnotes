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
        harness.coordinator.handleBackgroundEvents(identifier: harness.sessionIdentifier) {
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
        harness.coordinator.handleBackgroundEvents(identifier: harness.sessionIdentifier) {
            harness.scheduler.record("released-system-handler")
        }
        harness.delegate.urlSession(harness.session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.session)
        try await harness.waitForSystemHandler()

        #expect(harness.scheduler.log.last == "released-system-handler")
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [job.id])
    }

    /// UIKit hands the completion handler over before the session delivers its
    /// delegate events, so registration has to land before any of them drain.
    @Test func backgroundHandlerRegisteredJustBeforeTheEventsStillRuns() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()
        let task = harness.uploadTask(for: job.id)

        harness.coordinator.handleBackgroundEvents(identifier: harness.sessionIdentifier) {
            harness.scheduler.record("released-system-handler")
        }
        harness.delegate.urlSession(harness.session, task: task, didCompleteWithError: nil)
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.session)
        try await harness.waitForSystemHandler()

        #expect(harness.scheduler.log == ["discard:\(job.id)", "released-system-handler"])
    }

    /// A revoked device gets 401 forever, so the job must wait for a new pairing
    /// instead of sitting out an exponential backoff that cannot help it.
    @Test func revokedDeviceClearsTheBackoffAndTheStoredPairing() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()
        let inbox = try PendingUploadInbox(directory: harness.inboxDirectory)
        try await inbox.markFailed(job.id)
        #expect(await inbox.pending().isEmpty)

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 401)

        #expect(harness.scheduler.log.contains("authorization-rejected"))
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending().map(\.id) == [job.id])
    }

    /// The App Group must not accumulate a second full-size copy of every
    /// recording: once the durable job owns the audio, the staging copy goes.
    @Test func enqueueConsumesTheStagedSourceRecording() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let source = harness.root.appendingPathComponent("staged-recording.m4a")
        try Data("recording".utf8).write(to: source)

        let job = try await harness.coordinator.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: job.audioURL.path))
    }

    @Test func rejectedUploadResponseKeepsTheRecordingQueued() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 500)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [job.id])
    }

    @Test func acceptedUploadResponseKeepsTheRecordingQueued() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 202)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [job.id])
    }

    @Test func concurrentInboxChangesPreserveTheNewUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = root.appendingPathComponent("first.m4a")
        let secondSource = root.appendingPathComponent("second.m4a")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let directory = root.appendingPathComponent("uploads", isDirectory: true)
        let firstProcess = try PendingUploadInbox(directory: directory)
        let first = try await firstProcess.enqueue(audioAt: firstSource, metadata: .init(source: .iphoneRecording))
        let appProcess = try PendingUploadInbox(directory: directory)
        let extensionProcess = try PendingUploadInbox(directory: directory)

        async let completion: Void = appProcess.markCompleted(first.id)
        async let enqueue: PendingUpload = extensionProcess.enqueue(audioAt: secondSource, metadata: .init(source: .iphoneRecording))
        _ = try await (completion, enqueue)

        let reopened = try PendingUploadInbox(directory: directory)
        #expect(await reopened.pending(now: .distantFuture).count == 1)
    }

    @Test func sharedAudioSweepRemovesOrphanedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphan)
        SharedAudioStaging.sweepOrphans(in: directory)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func onlyFinishedUploadOutcomesReturnCompletionStatuses() {
        #expect(MacSyncServer.responseStatus(for: .created) == .created)
        #expect(MacSyncServer.responseStatus(for: .alreadyStored) == .ok)
        #expect(MacSyncServer.responseStatus(for: .resumed) == .accepted)
        #expect(MacSyncServer.responseStatus(for: .inProgress) == .conflict)
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

    /// A refresh that changes nothing must leave the transcript alone: deleting
    /// and re-inserting the same unique identifiers in one unsaved SwiftData
    /// transaction has no defined ordering and can empty the transcript.
    @Test func mirrorRefreshUpdatesRetainedSegmentsInPlace() throws {
        let callID = UUID()
        let store = FakeMirrorStore()
        func snapshot(_ segments: [SyncDTO.MirroredSegment]) -> SyncDTO.Mirror {
            SyncDTO.Mirror(calls: [
                SyncDTO.MirroredCall(
                    id: callID,
                    title: "Call with Priya",
                    summary: "Discussed the rollout",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    source: "iphone_recording",
                    status: "notes_ready",
                    segments: segments,
                    note: .init(summary: "Rollout", decisions: [], actionItems: [])
                )
            ])
        }
        let first = SyncDTO.MirroredSegment(id: "\(callID.uuidString)-0", speaker: "Priya", text: "Hello.", startSec: 0)
        let second = SyncDTO.MirroredSegment(id: "\(callID.uuidString)-1", speaker: "You", text: "Hi.", startSec: 2)

        try MirrorReconciler.apply(snapshot([first, second]), to: store)
        #expect(store.removedSegmentIDs.isEmpty)

        let reworded = SyncDTO.MirroredSegment(id: first.id, speaker: "Priya", text: "Hello again.", startSec: 0)
        try MirrorReconciler.apply(snapshot([reworded]), to: store)

        #expect(store.removedSegmentIDs == [second.id])
        #expect(store.segmentIDs(callID: callID) == [first.id])
        #expect(store.segments[first.id]?.text == "Hello again.")
        #expect(store.notes[callID] != nil)
    }

    #if os(macOS)
    /// `POST /calls/:uploadID` streams its body through `MultipartStreamParser`,
    /// so every framing guarantee is proven against that parser, fed in chunks
    /// small enough to split the closing delimiter across appends.
    @Test func streamedMultipartUploadWritesAudioAcrossSplitChunks() throws {
        let root = try MultipartFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = CallUploadMetadata(source: .iphoneRecording, counterpartyName: "Priya")
        let audio = Data(repeating: 0x7F, count: 128 * 1024) + Data([0x0D, 0x0A])
        let body = try MultipartFixture.body(metadata: metadata, filename: "recording.m4a", audio: audio)
        let uploadID = UUID()

        let upload = try #require(try MultipartFixture.stream(body, directory: root, uploadID: uploadID, chunkSize: 4093))
        #expect(upload.metadata == metadata)
        #expect(upload.audioURL.lastPathComponent == "\(uploadID.uuidString).m4a")
        #expect(try Data(contentsOf: upload.audioURL) == audio)
    }

    @Test func streamedUploadWithAJSONFilenameCannotOverwriteTheSidecar() throws {
        let root = try MultipartFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadID = UUID()
        let sidecar = root.appendingPathComponent("\(uploadID.uuidString).json")
        try Data("{\"kept\":true}".utf8).write(to: sidecar)
        let body = try MultipartFixture.body(
            metadata: CallUploadMetadata(source: .iphoneRecording),
            filename: "\(uploadID.uuidString).json",
            audio: Data("audio bytes".utf8)
        )

        let upload = try #require(try MultipartFixture.stream(body, directory: root, uploadID: uploadID, chunkSize: 17))
        #expect(upload.audioURL.pathExtension == "m4a")
        #expect(try Data(contentsOf: sidecar) == Data("{\"kept\":true}".utf8))
    }

    @Test func streamedUploadWithEmptyAudioIsRejectedAndLeavesNoStagingFile() throws {
        let root = try MultipartFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadID = UUID()
        let body = try MultipartFixture.body(
            metadata: CallUploadMetadata(source: .iphoneRecording),
            filename: "recording.m4a",
            audio: Data()
        )

        let rejected = try MultipartFixture.stream(body, directory: root, uploadID: uploadID, chunkSize: 11)
        #expect(rejected?.audioURL == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(uploadID.uuidString).m4a").path))
    }

    @Test func interruptedStreamedUploadDeletesItsPartialStagingFile() throws {
        let root = try MultipartFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadID = UUID()
        let body = try MultipartFixture.body(
            metadata: CallUploadMetadata(source: .iphoneRecording),
            filename: "recording.m4a",
            audio: Data(repeating: 0x11, count: 4096)
        )

        var parser = try MultipartStreamParser(boundary: MultipartFixture.boundary, directory: root, uploadID: uploadID)
        try parser.append(body.prefix(body.count - 64))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(uploadID.uuidString).m4a").path))
        parser.abort()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(uploadID.uuidString).m4a").path))
    }

    @Test func streamedUploadRejectsAFirstPartThatIsNotMetadata() throws {
        let root = try MultipartFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var parser = try MultipartStreamParser(boundary: MultipartFixture.boundary, directory: root, uploadID: UUID())
        defer { parser.abort() }
        #expect(throws: Error.self) {
            try parser.append(Data("Content-Disposition: form-data; name=\"audio\"\r\n\r\n".utf8))
        }
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
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, processingAttemptLimit: 1, onAccepted: { callID, _, _ in
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

    /// `.transcribed` means segments exist and notes still need to run. A later
    /// POST of the same upload ID must resume, not report the call already done.
    @Test func transcribedCallWithoutNotesResumesInsteadOfReportingAlreadyStored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-transcribed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let attempts = ProcessingAttempts()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, processingAttemptLimit: 1, onAccepted: { callID, _, _ in
            guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
            if await attempts.record() == 1 {
                call.status = .transcribed
                try await store.upsertCall(call)
                throw ProcessingFailure()
            }
            call.status = .notesReady
            try await store.upsertCall(call)
        })
        let uploadID = UUID()
        let metadata = CallUploadMetadata(source: .iphoneRecording, startedAt: Date(timeIntervalSince1970: 1_700_000_000), counterpartyName: "Priya")

        #expect(try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("recording".utf8), fileExtension: "m4a") == .created)

        var retry = MacSyncServer.UploadOutcome.alreadyStored
        for _ in 0..<200 where retry != .resumed {
            retry = try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("recording".utf8), fileExtension: "m4a")
            if retry != .resumed { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(retry == .resumed)

        var processed = try await store.fetchCall(id: uploadID)
        for _ in 0..<200 where processed?.status != .notesReady {
            try await Task.sleep(for: .milliseconds(10))
            processed = try await store.fetchCall(id: uploadID)
        }
        #expect(processed?.status == .notesReady)
        #expect(try await store.fetchCalls().count == 1)
        #expect(await attempts.count == 2)
    }

    /// The phone drops its queued job as soon as it sees 201, so recovery from a
    /// processing failure has to happen on the Mac with no further client POST.
    @Test func macRetriesFailedProcessingLocallyAfterAcknowledgingTheUpload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-local-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        let attempts = ProcessingAttempts()
        let server = MacSyncServer(
            store: store,
            receivedUploadsDirectory: root,
            processingRetryDelay: .milliseconds(10),
            processingAttemptLimit: 4,
            onAccepted: { callID, _, _ in
                if await attempts.record() < 3 { throw ProcessingFailure() }
                guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
                call.status = .notesReady
                try await store.upsertCall(call)
            }
        )
        let uploadID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = CallUploadMetadata(source: .iphoneRecording, startedAt: startedAt, counterpartyName: "Priya")

        let created = try await server.accept(uploadID: uploadID, metadata: metadata, audio: Data("recording".utf8), fileExtension: "m4a")
        #expect(created == .created)

        var processed = try await store.fetchCall(id: uploadID)
        for _ in 0..<400 where processed?.status != .notesReady {
            try await Task.sleep(for: .milliseconds(10))
            processed = try await store.fetchCall(id: uploadID)
        }
        #expect(processed?.status == .notesReady)
        #expect(processed?.startedAt == startedAt)
        #expect(await attempts.count == 3)
        #expect(try await store.fetchCalls().count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(uploadID.uuidString).m4a").path))
    }

    /// A call the Mac gave up on must not keep reading as work in progress on
    /// the phone, where the mirrored summary is the only visible status.
    @Test func mirrorDoesNotDescribeAGivenUpRecordingAsStillProcessing() async throws {
        let store = MemoryStore()
        let server = MacSyncServer(store: store)
        let callID = UUID()
        try await store.upsertCall(Call(
            id: callID,
            source: .iphoneRecording,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            counterpartyName: "Priya",
            audioPath: "/tmp/\(callID.uuidString).m4a",
            sttProvider: .appleSpeech,
            status: .failed
        ))

        let mirrored = try #require(try await server.mirror().calls.first)
        #expect(mirrored.status == CallStatus.failed.rawValue)
        #expect(mirrored.summary == "Could not finish this recording")
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

#if os(macOS)
/// Builds the exact wire bytes the phone's background session sends, so the
/// production stream parser is exercised over a real request body.
private enum MultipartFixture {
    static let boundary = "CallNotes-stream"

    static func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-multipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func body(metadata: CallUploadMetadata, filename: String, audio: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        body.append(try encoder.encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func stream(_ body: Data, directory: URL, uploadID: UUID, chunkSize: Int) throws -> MultipartCallUpload.StagedUpload? {
        var parser = try MultipartStreamParser(boundary: boundary, directory: directory, uploadID: uploadID)
        defer { parser.abort() }
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = body.index(offset, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            try parser.append(Data(body[offset..<end]))
            offset = end
        }
        return try parser.finish()
    }
}
#endif

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
    func authorizationRejected() async { record("authorization-rejected") }
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
        delegate = SessionUploadDelegate(
            coordinator: coordinator,
            pinnedFingerprint: { nil },
            statusCodeForTask: { _ in 201 }
        )
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
    private(set) var segments: [String: SyncDTO.MirroredSegment] = [:]
    private(set) var owners: [String: UUID] = [:]
    private(set) var notes: [UUID: SyncDTO.MirroredNote] = [:]
    private(set) var removedSegmentIDs: [String] = []

    func segmentIDs(callID: UUID) -> [String] {
        owners.filter { $0.value == callID }.keys.sorted()
    }

    func localCallIDs() throws -> [UUID] { Array(calls.keys) }
    func localSegmentIDs(callID: UUID) throws -> [String] { segmentIDs(callID: callID) }

    func removeSegment(id: String) throws {
        removedSegmentIDs.append(id)
        segments[id] = nil
        owners[id] = nil
    }

    func removeSegments(callID: UUID) throws {
        for id in segmentIDs(callID: callID) { try removeSegment(id: id) }
    }

    func removeNote(callID: UUID) throws { notes[callID] = nil }
    func removeCall(id: UUID) throws { calls[id] = nil }
    func upsertCall(_ call: SyncDTO.MirroredCall) throws { calls[call.id] = call }

    func upsertSegment(_ segment: SyncDTO.MirroredSegment, callID: UUID) throws {
        segments[segment.id] = segment
        owners[segment.id] = callID
    }

    func upsertNote(_ note: SyncDTO.MirroredNote, callID: UUID) throws { notes[callID] = note }
    func commit() throws {}
}
