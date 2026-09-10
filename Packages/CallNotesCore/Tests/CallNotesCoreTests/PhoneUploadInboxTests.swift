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
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { _, _, _ in
            await counter.record()
        })
        let uploadID = UUID()
        let metadata = CallUploadMetadata(source: .iphoneRecording)
        async let first = server.accept(uploadID: uploadID, metadata: metadata, audio: Data("first".utf8), fileExtension: "m4a")
        async let second = server.accept(uploadID: uploadID, metadata: metadata, audio: Data("second".utf8), fileExtension: "m4a")
        let outcomes = try await [first, second]
        #expect(outcomes.filter { $0 == .created }.count == 1)
        #expect(outcomes.contains(.inProgress))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 1)
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
