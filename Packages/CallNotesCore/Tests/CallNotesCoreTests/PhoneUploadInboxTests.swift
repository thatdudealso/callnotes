import Darwin
import Foundation
import Security
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

    /// A file-backed share hands over a filename, not a bare title, so the start
    /// time must survive the extension the provider appends.
    @Test func fileBackedShareNameStillPrefillsTheStartTime() throws {
        let metadata = try #require(
            SharedRecordingTitleParser.parse("Call with Priya Shah, Sep 10, 2026 at 1:30 PM.m4a")
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

    /// A share title is not a file path: a slash in the counterparty name must
    /// not truncate it while the extension is being trimmed.
    @Test func aCounterpartyNameContainingASlashSurvivesTheFilenameSuffix() throws {
        let metadata = try #require(
            SharedRecordingTitleParser.parse("Call with A/B Growth, Sep 10, 2026 at 1:30 PM.m4a")
        )

        #expect(metadata.counterpartyName == "A/B Growth")
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: try #require(metadata.startedAt)
        )
        #expect(components.year == 2026)
        #expect(components.hour == 13)
        #expect(components.minute == 30)
    }

    /// Only audio extensions are dropped; a surname after a period is not one.
    @Test func aTitleEndingInAnAbbreviationKeepsItsCounterparty() throws {
        let metadata = try #require(
            SharedRecordingTitleParser.parse("Call with Smith Jr., Sep 10, 2026 at 1:30 PM")
        )

        #expect(metadata.counterpartyName == "Smith Jr.")
        #expect(metadata.startedAt != nil)
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

    @Test func enqueueRollsBackItsCopiedFileWhenManifestPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let inbox = try PendingUploadInbox(
            directory: directory,
            persistenceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        await #expect(throws: CocoaError.self) {
            _ = try await inbox.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
        }
        #expect(await inbox.pending().isEmpty)
        let uploads = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("uploads", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(uploads.isEmpty)
    }

    /// Deleting the audio before the shortened manifest is durable would leave an
    /// entry the next process reloads but can never start, complete, or sweep,
    /// because `pending()` drops entries whose file is gone.
    @Test func completionThatCannotPersistKeepsTheQueuedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let inbox = try PendingUploadInbox(directory: directory)
        let job = try await inbox.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))

        let failingInbox = try PendingUploadInbox(
            directory: directory,
            persistenceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        await #expect(throws: CocoaError.self) {
            try await failingInbox.markCompleted(job.id)
        }

        #expect(FileManager.default.fileExists(atPath: job.audioURL.path))
        #expect(await failingInbox.pending().map(\.id) == [job.id])
        let reopened = try PendingUploadInbox(directory: directory)
        #expect(await reopened.pending().map(\.id) == [job.id])
    }

    /// A share extension killed mid-copy leaves a full-size file in `uploads/`
    /// that no manifest entry names, so nothing would ever start, complete, or
    /// clean it.
    @Test func launchSweepDropsUnqueuedUploadsAndKeepsPendingOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let inbox = try PendingUploadInbox(directory: directory)
        let job = try await inbox.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
        let orphan = directory
            .appendingPathComponent("uploads", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("abandoned".utf8).write(to: orphan)

        let relaunched = try PendingUploadInbox(directory: directory)
        await relaunched.sweepOrphans()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: job.audioURL.path))
        #expect(await inbox.pending().map(\.id) == [job.id])
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

    /// A task queued before the pairing was cleared still gets its TLS
    /// challenge later. Without a pin there is nothing to compare the Mac's
    /// self-signed certificate against, so the transfer must fail rather than
    /// fall back to system trust.
    @Test func serverTrustChallengeIsCancelledWhenNoPinIsAvailable() throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }

        let disposition = harness.disposition(forAuthenticationMethod: NSURLAuthenticationMethodServerTrust)

        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test func nonServerTrustChallengeStillUsesDefaultHandling() throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }

        let disposition = harness.disposition(forAuthenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        #expect(disposition == .performDefaultHandling)
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

    /// The Sync button is the only affordance for forcing a queued recording,
    /// so it ignores the retry backoff. An automatic launch resume must not, or
    /// every launch rebuilds the whole multipart body of every backed-off job
    /// against a Mac that is still unreachable.
    @Test func onlyAUserInitiatedResumeStartsABackedOffUpload() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()
        let inbox = try PendingUploadInbox(directory: harness.inboxDirectory)
        try await inbox.markFailed(job.id)
        #expect(await inbox.pending().isEmpty)

        await harness.coordinator.resume()

        #expect(harness.scheduler.log == [])

        await harness.coordinator.resume(includeBackedOff: true)

        #expect(harness.scheduler.log == ["start:\(job.id)"])
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

    /// The drop destroys the phone's only copy, so it cannot be silent: the
    /// starter hears about it now, and a process that was not running when the
    /// background session settled the task still finds it in the inbox.
    @Test func clientErrorResponseDropsTheRejectedRecordingAndReportsIt() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let source = harness.root.appendingPathComponent("rejected.m4a")
        try Data("recording".utf8).write(to: source)
        let sharingProcess = try PendingUploadInbox(directory: harness.inboxDirectory)
        let job = try await sharingProcess.enqueue(
            audioAt: source,
            metadata: .init(source: .iphoneRecording, counterpartyName: "Priya Shah")
        )

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 400)

        #expect(harness.scheduler.log.contains("rejected:400:\(job.id)"))
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.audioURL.path))
        let rejections = await reopened.takeRejections()
        #expect(rejections.map(\.id) == [job.id])
        #expect(rejections.first?.statusCode == 400)
        let message = try #require(RejectedUpload.summary(of: rejections))
        #expect(message.contains("Priya Shah"))
        #expect(message.contains("400"))
        #expect(await reopened.takeRejections().isEmpty)
    }

    /// A blank Contact field in the share sheet means the user named nobody. An
    /// empty string is not that: it is non-nil, so every `?? "Call"` /
    /// `?? "Untitled call"` / `Speaker N` fallback keeps it and renders blank.
    @Test func aBlankShareSheetNameNeverReachesTheMacAsAnEmptyCounterparty() throws {
        #expect(CallUploadMetadata(source: .iphoneRecording, counterpartyName: "").counterpartyName == nil)
        #expect(CallUploadMetadata(source: .iphoneRecording, counterpartyName: "   ").counterpartyName == nil)
        #expect(CallUploadMetadata(source: .iphoneRecording, counterpartyName: nil).counterpartyName == nil)
        #expect(
            CallUploadMetadata(source: .iphoneRecording, counterpartyName: "  Priya Shah  ").counterpartyName
                == "Priya Shah"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("New Recording 3.m4a")
        try Data("recording".utf8).write(to: audioURL)
        let job = PendingUpload(
            audioURL: audioURL,
            metadata: .init(source: .iphoneRecording, startedAt: Date(timeIntervalSince1970: 1_700_000_000), counterpartyName: "")
        )

        let body = try MultipartUploadBody.make(job: job, directory: root.appendingPathComponent("requests", isDirectory: true))
        let boundary = try #require(body.contentType.components(separatedBy: "boundary=").last)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var parser = try MultipartStreamParser(boundary: boundary, directory: staging, uploadID: job.id)
        try parser.append(try Data(contentsOf: body.url))
        let staged = try #require(try parser.finish())

        #expect(staged.metadata.counterpartyName == nil)
    }

    /// The blank-name rule has to survive decoding, not just construction: a job
    /// an older build queued with an empty Contact field is still sitting in the
    /// App Group manifest after an app update, and the Mac decodes whatever the
    /// phone encodes.
    @Test func decodingABlankCounterpartyNameYieldsNoNameAtAll() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let blank = try decoder.decode(
            CallUploadMetadata.self,
            from: Data(#"{"source":"iphone_recording","counterpartyName":""}"#.utf8)
        )
        let whitespace = try decoder.decode(
            CallUploadMetadata.self,
            from: Data(#"{"source":"iphone_recording","counterpartyName":"   "}"#.utf8)
        )
        let named = try decoder.decode(
            CallUploadMetadata.self,
            from: Data(#"{"source":"iphone_recording","counterpartyName":"  Priya Shah  "}"#.utf8)
        )

        #expect(blank.counterpartyName == nil)
        #expect(whitespace.counterpartyName == nil)
        #expect(named.counterpartyName == "Priya Shah")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let uploads = directory.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let audioURL = uploads.appendingPathComponent("queued.m4a")
        try Data("recording".utf8).write(to: audioURL)
        let staleManifest = """
        [{"id":"\(UUID().uuidString)","audioURL":"\(audioURL.absoluteString)",        "metadata":{"source":"iphone_recording","counterpartyName":""},        "createdAt":"2026-09-10T13:30:00Z","retryCount":0}]
        """
        try Data(staleManifest.utf8).write(to: directory.appendingPathComponent("pending-uploads.json"))

        let inbox = try PendingUploadInbox(directory: directory)

        let queued = try #require(await inbox.pending(now: .distantFuture).first)
        #expect(queued.metadata.counterpartyName == nil)

        let sidecarAudio = root.appendingPathComponent("sidecar.m4a")
        try Data(#"{"source":"iphone_recording","counterpartyName":"   "}"#.utf8)
            .write(to: CallUploadMetadata.sidecarURL(nextTo: sidecarAudio))
        #expect(CallUploadMetadata.loadSidecar(nextTo: sidecarAudio)?.counterpartyName == nil)
    }

    /// Opening the inbox is what the app does on launch and on a background
    /// relaunch, from the main thread. The Share Extension can be holding the
    /// manifest lock across a copy of an hour-long recording, so construction
    /// must not be what waits for it.
    @Test func openingTheInboxDoesNotWaitOnTheLockAnotherProcessHolds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let queued = try await PendingUploadInbox(directory: directory)
            .enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
        let lockURL = directory.appendingPathComponent("pending-uploads.lock")

        let held = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)

        let opened = FlagBox()
        let reopen = Task.detached {
            let inbox = try PendingUploadInbox(directory: directory)
            opened.set()
            return inbox
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(opened.isSet)

        #expect(flock(held, LOCK_UN) == 0)
        close(held)
        let reopened = try await reopen.value
        #expect(await reopened.pending(now: .distantFuture).map(\.id) == [queued.id])
    }

    /// One `SessionUploadDelegate` backs both background sessions. A drain that
    /// the share session triggers must not retire the phone session's durable
    /// transition, or the phone session reports "done" to iOS while its own
    /// `markCompleted` is still running and can be suspended mid-write.
    @Test func eachBackgroundSessionDrainsOnlyItsOwnTransitions() async throws {
        let harness = try TwoSessionHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()
        let task = harness.uploadTask(for: job.id, on: harness.phoneSession)

        harness.coordinator.handleBackgroundEvents(identifier: harness.phoneIdentifier) {
            harness.scheduler.record("released-phone-handler")
        }
        harness.delegate.urlSession(harness.phoneSession, task: task, didCompleteWithError: nil)
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.shareSession)
        harness.delegate.urlSessionDidFinishEvents(forBackgroundURLSession: harness.phoneSession)
        try await Task.sleep(for: .milliseconds(250))

        #expect(harness.scheduler.log == [])

        harness.scheduler.openGate()
        try await harness.waitFor("released-phone-handler")

        #expect(harness.scheduler.log == ["discard:\(job.id)", "released-phone-handler"])
        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).isEmpty)
    }

    /// The app and the Share Extension now POST bodies from one writer, and the
    /// Mac is the only reader of that format: a body it cannot parse is answered
    /// 400, which deletes the recording instead of retrying it.
    @Test func theSharedMultipartBodyIsWhatTheMacsParserAccepts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("recording.m4a")
        let audio = Data((0..<200_000).map { UInt8($0 % 251) })
        try audio.write(to: audioURL)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let job = PendingUpload(
            audioURL: audioURL,
            metadata: .init(source: .iphoneMeeting, startedAt: startedAt, counterpartyName: "Priya Shah")
        )

        let body = try MultipartUploadBody.make(job: job, directory: root.appendingPathComponent("requests", isDirectory: true))

        let boundary = try #require(body.contentType.components(separatedBy: "boundary=").last)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var parser = try MultipartStreamParser(boundary: boundary, directory: staging, uploadID: job.id)
        let encoded = try Data(contentsOf: body.url)
        for chunk in stride(from: 0, to: encoded.count, by: 8192) {
            try parser.append(encoded.subdata(in: chunk..<min(chunk + 8192, encoded.count)))
        }
        let staged = try #require(try parser.finish())

        #expect(staged.metadata.source == .iphoneMeeting)
        #expect(staged.metadata.startedAt == startedAt)
        #expect(staged.metadata.counterpartyName == "Priya Shah")
        #expect(try Data(contentsOf: staged.audioURL) == audio)
    }

    /// 409 and 401 keep the job, so neither may leave a drop report behind.
    @Test func retainedResponsesNeverReportARejection() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 409)
        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 401)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending().map(\.id) == [job.id])
        #expect(await reopened.takeRejections().isEmpty)
    }

    /// The lock file is the only thing serializing the app against the Share
    /// Extension. Replacing its inode - which `FileManager.createFile` does -
    /// drops a lock another process is holding, so an operation must wait for a
    /// foreign holder rather than walking straight into the critical section.
    @Test func manifestLockWaitsForAHolderInAnotherProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let inbox = try PendingUploadInbox(directory: directory)
        let lockURL = directory.appendingPathComponent("pending-uploads.lock")

        let held = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)

        let finished = FlagBox()
        let enqueue = Task.detached {
            let job = try await inbox.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
            finished.set()
            return job
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(finished.isSet == false)

        let contender = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(contender >= 0)
        #expect(flock(contender, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        close(contender)

        #expect(flock(held, LOCK_UN) == 0)
        close(held)
        let job = try await enqueue.value

        #expect(FileManager.default.fileExists(atPath: job.audioURL.path))
        #expect(await inbox.pending().map(\.id) == [job.id])
    }

    /// 202 is the Mac resuming an upload it already holds, so the phone must
    /// release its copy instead of re-sending the whole recording on every
    /// launch until the Mac finally answers 200.
    @Test func resumedUploadResponseReleasesTheRecording() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 202)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending(now: .distantFuture).isEmpty)
    }

    /// 409 is the Mac accepting this same upload concurrently. The job stays
    /// exactly as it was: still queued, and not pushed behind a retry backoff.
    @Test func conflictResponseLeavesTheUploadQueuedWithoutBackoff() async throws {
        let harness = try RelaunchHarness()
        defer { harness.tearDown() }
        let job = try await harness.enqueueRecording()

        await harness.coordinator.taskCompleted(uploadID: job.id, error: nil, statusCode: 409)

        let reopened = try PendingUploadInbox(directory: harness.inboxDirectory)
        #expect(await reopened.pending().map(\.id) == [job.id])
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

    /// The app sweeps `SharedAudio` on every launch while the Share Extension
    /// may still be copying into it, so the sweep must collect only the files
    /// nobody holds a lease on.
    @Test func sharedAudioSweepSparesLeasedFilesAndCollectsOrphans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let orphan = directory.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphan)
        let leased = directory.appendingPathComponent("in-flight.m4a")
        let lease = try SharedAudioStaging.Lease(audioURL: leased)
        try Data("in flight".utf8).write(to: leased)

        SharedAudioStaging.sweepOrphans(in: directory)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: leased.path))

        lease.release()
        SharedAudioStaging.sweepOrphans(in: directory)
        #expect(!FileManager.default.fileExists(atPath: leased.path))
    }

    /// The app and the Share Extension must derive one access group, and a
    /// keychain refusal has to name it instead of reading as a file error.
    @Test func pairingKeychainNamesItsSharedAccessGroupWhenAnOperationFails() {
        #expect(PairingKeychain.itemQuery(account: "device")[kSecAttrAccessGroup] as? String == PairingKeychain.accessGroup)
        #expect(PairingKeychain.serviceQuery()[kSecAttrAccessGroup] as? String == PairingKeychain.accessGroup)

        let message = PairingKeychain.failure(errSecMissingEntitlement).localizedDescription
        #expect(message.contains(PairingKeychain.accessGroup))
        #expect(message.contains("\(errSecMissingEntitlement)"))
    }

    /// `GET /mirror` is encoded by Hummingbird's default response encoder, which
    /// is `.iso8601`. A client decoder that disagrees reads `startedAt` as a
    /// `Double` and the phone never renders a single call.
    @Test func mirrorSurvivesTheWireFormatTheServerActuallyEncodes() throws {
        let callID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let mirror = SyncDTO.Mirror(calls: [
            SyncDTO.MirroredCall(
                id: callID,
                title: "Call with Priya",
                summary: "Discussed the rollout",
                startedAt: startedAt,
                source: "iphone_recording",
                status: "notes_ready",
                segments: [.init(id: "\(callID.uuidString)-0", speaker: "Priya", text: "Hello.", startSec: 0)],
                note: .init(summary: "Rollout", decisions: ["Ship"], actionItems: ["Email Priya"])
            )
        ])

        let serverEncoder = JSONEncoder()
        serverEncoder.dateEncodingStrategy = .iso8601
        let body = try serverEncoder.encode(mirror)

        let decoded = try SyncCoder.decoder().decode(SyncDTO.Mirror.self, from: body)

        #expect(decoded.calls.count == 1)
        #expect(decoded.calls[0].id == callID)
        #expect(decoded.calls[0].startedAt == startedAt)
        #expect(decoded.calls[0].segments.map(\.text) == ["Hello."])
        #expect(decoded.calls[0].note?.actionItems == ["Email Priya"])
    }

    /// Hummingbird wraps a thrown `HTTPError` message in `{"error":{"message":}}`.
    /// The user gets the sentence, never the envelope.
    @Test func serverErrorBodyYieldsTheSentenceNotTheEnvelope() throws {
        let consumed = "That pairing code is no longer valid. Show a new QR code on your Mac."
        let envelope = try #require(#"{"error":{"message":"\#(consumed)"}}"#.data(using: .utf8))

        #expect(SyncErrorBody.message(from: envelope) == consumed)
        #expect(SyncErrorBody.message(from: Data("plain failure text".utf8)) == "plain failure text")
        #expect(SyncErrorBody.message(from: Data()) == nil)
    }

    /// The unpaired case is the first thing a new user hits, so it has to read
    /// as a pairing instruction rather than fall back to a Foundation status.
    @Test func notPairedErrorExplainsThePairingStepItself() {
        let message = PairingCredentialError.notPaired.localizedDescription

        #expect(message != URLError(.userAuthenticationRequired).localizedDescription)
        #expect(message.contains("Pair this iPhone with your Mac"))
        #expect(message.contains("Settings"))
    }

    /// A process relaunched before first unlock cannot read its own probe item.
    /// Pinning that miss would leave the unentitled bare group in place until the
    /// app is killed, so only a resolution that reached the keychain is kept.
    @Test func accessGroupRetriesUntilTheSignedGroupResolves() {
        let signed = "A1B2C3D4E5.\(SyncConstants.appGroupIdentifier)"
        let attempts = ProbeAttempts()
        let resolver = PairingKeychain.ResolvedAccessGroup(signedDefaultAccessGroup: {
            attempts.count += 1
            return attempts.count > 2 ? signed : nil
        })

        #expect(resolver.value() == SyncConstants.appGroupIdentifier)
        #expect(resolver.value() == SyncConstants.appGroupIdentifier)
        #expect(resolver.value() == signed)
        #expect(resolver.value() == signed)
        #expect(attempts.count == 3)
    }

    /// `keychain-access-groups` is entitled as `$(AppIdentifierPrefix)group...`,
    /// so the group the app requests has to carry the same team prefix the
    /// signer applied - taken from the group the keychain hands this process.
    @Test func sharedAccessGroupCarriesTheSignedTeamPrefix() {
        let shared = SyncConstants.appGroupIdentifier

        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: "A1B2C3D4E5.\(shared)") == "A1B2C3D4E5.\(shared)")
        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: "A1B2C3D4E5.com.thatdudealso.callnotes.ios") == "A1B2C3D4E5.\(shared)")
        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: "A1B2C3D4E5.com.thatdudealso.callnotes.ios.ShareExtension") == "A1B2C3D4E5.\(shared)")
        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: shared) == shared)
        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: nil) == shared)
        #expect(PairingKeychain.sharedAccessGroup(defaultAccessGroup: "") == shared)
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

    @Test func serverStartupResumesTranscribedStagingWithoutAnotherUpload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore()
        let uploadID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let audioURL = root.appendingPathComponent("\(uploadID.uuidString).m4a")
        try Data("recording".utf8).write(to: audioURL)
        let metadata = CallUploadMetadata(source: .iphoneRecording, startedAt: startedAt, counterpartyName: "Priya")
        try metadata.writeSidecar(nextTo: audioURL)
        try await store.upsertCall(Call(
            id: uploadID,
            source: metadata.source,
            startedAt: startedAt,
            counterpartyName: metadata.counterpartyName,
            audioPath: audioURL.path,
            sttProvider: .appleSpeech,
            status: .transcribed
        ))
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { callID, _, _ in
            guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
            call.status = .notesReady
            try await store.upsertCall(call)
        })

        await server.recoverStagedUploads()

        var recovered = try await store.fetchCall(id: uploadID)
        for _ in 0..<200 where recovered?.status != .notesReady {
            try await Task.sleep(for: .milliseconds(10))
            recovered = try await store.fetchCall(id: uploadID)
        }
        #expect(recovered?.status == .notesReady)
        #expect(recovered?.id == uploadID)
        #expect(recovered?.startedAt == startedAt)
        #expect(try await store.fetchCalls().count == 1)
    }

    /// Each stuck upload drives a whole transcription spine, so the launch sweep
    /// must walk the backlog one at a time instead of fanning it out.
    @Test func startupRecoveryProcessesStuckUploadsOneAtATime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-recovery-serial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = MemoryStore()
        var uploadIDs: [UUID] = []
        for _ in 0..<4 {
            let uploadID = UUID()
            uploadIDs.append(uploadID)
            let audioURL = root.appendingPathComponent("\(uploadID.uuidString).m4a")
            try Data("recording".utf8).write(to: audioURL)
            try CallUploadMetadata(source: .iphoneRecording, startedAt: Date()).writeSidecar(nextTo: audioURL)
            try await store.upsertCall(Call(
                id: uploadID,
                source: .iphoneRecording,
                startedAt: Date(),
                audioPath: audioURL.path,
                sttProvider: .appleSpeech,
                status: .transcribed
            ))
        }

        let concurrency = ConcurrencyProbe()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { callID, _, _ in
            concurrency.enter()
            defer { concurrency.leave() }
            try await Task.sleep(for: .milliseconds(20))
            guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
            call.status = .notesReady
            try await store.upsertCall(call)
        })

        await server.recoverStagedUploads()

        #expect(concurrency.peak == 1)
        #expect(concurrency.completed == uploadIDs.count)
        for uploadID in uploadIDs {
            #expect(try await store.fetchCall(id: uploadID)?.status == .notesReady)
        }
    }

    /// The staging path a POST streams into is the same path recovery looks for,
    /// so recovering a reserved upload would transcribe a half-written file and
    /// then answer 200 for it, letting the phone delete the only full copy.
    @Test func startupRecoverySkipsAnUploadAPostIsStillStreaming() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-recovery-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = MemoryStore()
        let uploadID = UUID()
        let audioURL = root.appendingPathComponent("\(uploadID.uuidString).m4a")
        try Data("partially written".utf8).write(to: audioURL)
        try CallUploadMetadata(source: .iphoneRecording, startedAt: Date()).writeSidecar(nextTo: audioURL)
        try await store.upsertCall(Call(
            id: uploadID,
            source: .iphoneRecording,
            startedAt: Date(),
            audioPath: audioURL.path,
            sttProvider: .appleSpeech,
            status: .transcribed
        ))

        let recovered = RecoveredUploads()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root, onAccepted: { callID, _, _ in
            recovered.record(callID)
            guard var call = try await store.fetchCall(id: callID) else { throw ProcessingFailure() }
            call.status = .notesReady
            try await store.upsertCall(call)
        })

        #expect(await server.reserve(uploadID))
        await server.recoverStagedUploads()

        #expect(recovered.ids.isEmpty)
        #expect(try await store.fetchCall(id: uploadID)?.status == .transcribed)

        await server.release(uploadID)
        await server.recoverStagedUploads()

        #expect(recovered.ids == [uploadID])
        #expect(try await store.fetchCall(id: uploadID)?.status == .notesReady)
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

    /// Speaker profiles are global to the store, so one `GET /mirror` must read
    /// them once however much history the Mac holds - the phone triggers this on
    /// every Calls tab appearance.
    @Test func mirrorReadsTheSpeakerProfileTableOncePerRequest() async throws {
        let store = ProfileCountingStore()
        let server = MacSyncServer(store: store)
        try await store.upsertSpeakerProfile(
            SpeakerProfile(id: UUID(), displayName: "Priya", centroid: Array(repeating: 0.1, count: 8), embeddingModel: "test", sampleCount: 1)
        )
        for index in 0..<3 {
            let callID = UUID()
            try await store.upsertCall(Call(
                id: callID,
                source: .iphoneRecording,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                counterpartyName: "Priya",
                audioPath: "/tmp/\(callID.uuidString).m4a",
                sttProvider: .appleSpeech,
                status: .notesReady
            ))
            try await store.replaceSegments(callID: callID, provider: .appleSpeech, [
                Segment(callID: callID, seq: 0, startSec: 0, endSec: 1, channel: .near, text: "Hello.", provider: .appleSpeech)
            ])
        }

        let mirror = try await server.mirror()

        #expect(mirror.calls.count == 3)
        #expect(mirror.calls.allSatisfy { $0.segments.count == 1 })
        #expect(store.profileFetchCount == 1)
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

    @Test func phoneUploadCannotReplaceAMacCapturedCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-mac-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore()
        let callID = UUID()
        let originalPath = "/tmp/\(callID.uuidString)-mac.caf"
        try await store.upsertCall(Call(
            id: callID,
            source: .macFaceTime,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            counterpartyName: "Priya",
            audioPath: originalPath,
            sttProvider: .appleSpeech,
            status: .transcribed
        ))
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)

        do {
            _ = try await server.accept(
                uploadID: callID,
                metadata: CallUploadMetadata(source: .iphoneRecording),
                audio: Data("recording".utf8),
                fileExtension: "m4a"
            )
            Issue.record("phone upload of a Mac-captured call id should be rejected")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            #expect(text.contains("not a phone upload"))
        }
        let stored = try #require(try await store.fetchCall(id: callID))
        #expect(stored.source == .macFaceTime)
        #expect(stored.audioPath == originalPath)
        let staged = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    /// The iCloud Drive inbox stores its imports as `.iphoneRecording`, so the
    /// source alone does not make a call addressable: only a row this Mac wrote
    /// from an earlier phone POST, whose staging it still holds, may be resumed.
    @Test func phoneUploadCannotReplaceAnInboxImportCarryingAPhoneSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-inbox-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore()
        let callID = UUID()
        let originalPath = "/tmp/\(callID.uuidString)-inbox.wav"
        try await store.upsertCall(Call(
            id: callID,
            source: .iphoneRecording,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            counterpartyName: "Podcast",
            audioPath: originalPath,
            sttProvider: .appleSpeech,
            status: .failed
        ))
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)

        do {
            _ = try await server.accept(
                uploadID: callID,
                metadata: CallUploadMetadata(source: .iphoneRecording),
                audio: Data("recording".utf8),
                fileExtension: "m4a"
            )
            Issue.record("phone upload of an inbox-imported call id should be rejected")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            #expect(text.contains("not a phone upload"))
        }
        let stored = try #require(try await store.fetchCall(id: callID))
        #expect(stored.audioPath == originalPath)
        #expect(stored.status == .failed)
        let staged = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    /// The stored source decides which later uploads may resume an identifier,
    /// and whether the import pipeline treats the first attempt as an inbox
    /// retry that skips the content-hash duplicate check. A client does not get
    /// to name itself into either exemption.
    @Test func aClientSuppliedNonPhoneSourceIsStoredAsAPhoneUpload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callnotes-phone-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore()
        let server = MacSyncServer(store: store, receivedUploadsDirectory: root)
        let uploadID = UUID()

        let created = try await server.accept(
            uploadID: uploadID,
            metadata: CallUploadMetadata(source: .fileImport, counterpartyName: "Priya"),
            audio: Data("recording".utf8),
            fileExtension: "m4a"
        )

        #expect(created == .created)
        let stored = try #require(try await store.fetchCall(id: uploadID))
        #expect(stored.source == .iphoneRecording)
        #expect(stored.counterpartyName == "Priya")
        let audioURL = root.appendingPathComponent("\(uploadID.uuidString).m4a")
        #expect(CallUploadMetadata.loadSidecar(nextTo: audioURL)?.source == .iphoneRecording)
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
    func uploadRejected(_ job: PendingUpload, statusCode: Int) async { record("rejected:\(statusCode):\(job.id)") }
}

/// Holds each upload's durable transition open until the test releases it, so a
/// relaunch handler released too early is observable rather than a race.
private final class GatedScheduler: SessionUploadTaskStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var log: [String] { lock.withLock { events } }
    func record(_ event: String) { lock.withLock { events.append(event) } }
    func start(_ job: PendingUpload) async { record("start:\(job.id)") }
    func authorizationRejected() async { record("authorization-rejected") }

    func discardRequestBody(for uploadID: UUID) async {
        await withCheckedContinuation { continuation in
            let resume: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
        record("discard:\(uploadID)")
    }

    func openGate() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let all = waiters
            waiters = []
            return all
        }
        for continuation in pending { continuation.resume() }
    }
}

/// A relaunched app with both of its background sessions restored behind the one
/// delegate the production `BackgroundUploadCoordinator` builds.
private struct TwoSessionHarness {
    let root: URL
    let inboxDirectory: URL
    let phoneIdentifier: String
    let shareIdentifier: String
    let scheduler = GatedScheduler()
    let coordinator: SessionUploadCoordinator
    let delegate: SessionUploadDelegate
    let phoneSession: URLSession
    let shareSession: URLSession

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("callnotes-two-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        inboxDirectory = root.appendingPathComponent("shared", isDirectory: true)
        phoneIdentifier = "callnotes.test.phone-upload.\(UUID().uuidString)"
        shareIdentifier = "callnotes.test.share-upload.\(UUID().uuidString)"
        coordinator = try SessionUploadCoordinator(directory: inboxDirectory, starter: scheduler)
        delegate = SessionUploadDelegate(
            coordinator: coordinator,
            pinnedFingerprint: { nil },
            statusCodeForTask: { _ in 201 }
        )
        phoneSession = SharedUploadSession.make(identifier: phoneIdentifier, appGroupIdentifier: "", delegate: delegate)
        shareSession = SharedUploadSession.make(identifier: shareIdentifier, appGroupIdentifier: "", delegate: delegate)
    }

    func enqueueRecording() async throws -> PendingUpload {
        let source = root.appendingPathComponent("recording.m4a")
        try Data("recording".utf8).write(to: source)
        let sharingProcess = try PendingUploadInbox(directory: inboxDirectory)
        return try await sharingProcess.enqueue(audioAt: source, metadata: .init(source: .iphoneRecording))
    }

    func uploadTask(for uploadID: UUID, on session: URLSession) -> URLSessionTask {
        let body = root.appendingPathComponent("\(uploadID.uuidString).multipart")
        try? Data("body".utf8).write(to: body)
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(SyncConstants.serverPort)/calls/\(uploadID.uuidString)")!)
        request.httpMethod = "POST"
        let task = session.uploadTask(with: request, fromFile: body)
        task.taskDescription = uploadID.uuidString
        return task
    }

    func waitFor(_ event: String) async throws {
        for _ in 0..<200 where !scheduler.log.contains(event) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func tearDown() {
        phoneSession.invalidateAndCancel()
        shareSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A flag a detached task can set without the test having to await it, so a
/// blocked operation can be observed as still blocked.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
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

    func disposition(forAuthenticationMethod method: String) -> URLSession.AuthChallengeDisposition? {
        let space = URLProtectionSpace(
            host: "127.0.0.1",
            port: SyncConstants.serverPort,
            protocol: "https",
            realm: nil,
            authenticationMethod: method
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: InertChallengeSender()
        )
        var observed: URLSession.AuthChallengeDisposition?
        delegate.urlSession(session, didReceive: challenge) { disposition, _ in
            observed = disposition
        }
        return observed
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

/// A `MemoryStore` that reports how often the mirror re-reads the global speaker
/// profile table, which on Postgres is a full scan plus vector parsing per row.
private final class ProfileCountingStore: CallStore, @unchecked Sendable {
    private let wrapped = MemoryStore()
    private let lock = NSLock()
    private var profileFetches = 0

    var profileFetchCount: Int { lock.withLock { profileFetches } }

    func fetchSpeakerProfiles() async throws -> [SpeakerProfile] {
        lock.withLock { profileFetches += 1 }
        return try await wrapped.fetchSpeakerProfiles()
    }

    func migrate() async throws { try await wrapped.migrate() }
    func upsertCall(_ call: Call) async throws { try await wrapped.upsertCall(call) }
    func deleteCall(id: UUID) async throws { try await wrapped.deleteCall(id: id) }
    func fetchCalls() async throws -> [Call] { try await wrapped.fetchCalls() }
    func fetchCall(id: UUID) async throws -> Call? { try await wrapped.fetchCall(id: id) }
    func dashboardChanges() async -> AsyncStream<Void> { await wrapped.dashboardChanges() }

    func fetchPreferredNotesByCall() async throws -> [UUID: NotesRecord] {
        try await wrapped.fetchPreferredNotesByCall()
    }

    func closeStrandedRecordings(excluding liveCallID: UUID?) async throws -> [Call] {
        try await wrapped.closeStrandedRecordings(excluding: liveCallID)
    }

    func replaceSegments(callID: UUID, provider: STTProviderID, _ segments: [Segment]) async throws {
        try await wrapped.replaceSegments(callID: callID, provider: provider, segments)
    }

    func fetchSegments(callID: UUID, provider: STTProviderID?) async throws -> [Segment] {
        try await wrapped.fetchSegments(callID: callID, provider: provider)
    }

    func upsertSpeakerProfile(_ profile: SpeakerProfile) async throws { try await wrapped.upsertSpeakerProfile(profile) }

    func replaceCallSpeakers(callID: UUID, speakers: [CallSpeaker]) async throws {
        try await wrapped.replaceCallSpeakers(callID: callID, speakers: speakers)
    }

    func fetchCallSpeakers(callID: UUID) async throws -> [CallSpeaker] {
        try await wrapped.fetchCallSpeakers(callID: callID)
    }

    func insertSpeakerSample(profileID: UUID, embedding: [Float], embeddingModel: String, callID: UUID?, positive: Bool) async throws {
        try await wrapped.insertSpeakerSample(
            profileID: profileID,
            embedding: embedding,
            embeddingModel: embeddingModel,
            callID: callID,
            positive: positive
        )
    }

    func upsertNotes(_ record: NotesRecord) async throws { try await wrapped.upsertNotes(record) }
    func fetchNotes(callID: UUID) async throws -> [NotesRecord] { try await wrapped.fetchNotes(callID: callID) }
}

/// `URLAuthenticationChallenge` requires a sender; the delegate under test
/// answers through its completion handler and never touches this one.
private final class InertChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
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

private final class ProbeAttempts: @unchecked Sendable {
    var count = 0
}

private final class RecoveredUploads: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UUID] = []

    var ids: [UUID] { lock.withLock { recorded } }
    func record(_ id: UUID) { lock.withLock { recorded.append(id) } }
}


private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func enter() {
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
    }

    func leave() {
        lock.withLock {
            active -= 1
            completed += 1
        }
    }
}
