#if os(macOS)
import Foundation
import Hummingbird
import HummingbirdTLS
import NIOSSL

extension SyncDTO.HealthReport: ResponseCodable {}
extension SyncDTO.PairResponse: ResponseCodable {}
extension SyncDTO.Mirror: ResponseCodable {}

/// Hummingbird API hosted by the Mac app. TLS is mandatory and the QR payload
/// contains the leaf certificate fingerprint for the phone to pin.
public actor MacSyncServer {
    private let pairing: PairingAuthority
    private let store: any CallStore
    private let receivedUploadsDirectory: URL
    private let onAccepted: (@Sendable (UUID, URL, CallUploadMetadata) async throws -> Void)?
    private let processingRetryDelay: Duration
    private let processingAttemptLimit: Int
    private var acceptingUploadIDs: Set<UUID> = []
    private var processingUploadIDs: Set<UUID> = []

    public init(
        pairing: PairingAuthority = PairingAuthority(),
        store: any CallStore = MemoryStore(),
        receivedUploadsDirectory: URL? = nil,
        processingRetryDelay: Duration = .seconds(30),
        processingAttemptLimit: Int = 4,
        onAccepted: (@Sendable (UUID, URL, CallUploadMetadata) async throws -> Void)? = nil
    ) {
        self.pairing = pairing
        self.store = store
        self.receivedUploadsDirectory = receivedUploadsDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("CallNotesPhoneUploads", isDirectory: true)
        self.processingRetryDelay = processingRetryDelay
        self.processingAttemptLimit = max(1, processingAttemptLimit)
        self.onAccepted = onAccepted
    }

    public func pairingTicket(serverURL: URL, identity: MacTLSIdentity) async -> PairingTicket {
        await pairing.issueTicket(serverURL: serverURL, certificateFingerprint: identity.certificateFingerprint)
    }

    public func revoke(deviceID: UUID) async throws {
        try await pairing.revoke(deviceID: deviceID)
    }

    public func pairedDevices() async -> [PairedDevice] {
        await pairing.pairedDevices()
    }

    public func unsavedRevocationIDs() async -> Set<UUID> {
        await pairing.unsavedRevocationIDs()
    }

    /// One stuck upload at a time. Each one drives a whole `FileTranscriptionSpine`,
    /// so fanning the backlog out would run N SpeechAnalyzer instances against the
    /// same ANE and N deep-notes requests against the same 60s budget.
    public func recoverStagedUploads() async {
        guard let onAccepted else { return }
        let calls = (try? await store.fetchCalls()) ?? []
        for call in calls where !isProcessed(call) && Self.isPhoneUpload(call.source) {
            guard let audioURL = stagedAudioURL(for: call.id) else { continue }
            // The snapshot ages while earlier uploads transcribe, so re-read the
            // call: an arriving POST may already have carried this one home.
            guard let current = try? await store.fetchCall(id: call.id), !isProcessed(current) else { continue }
            // A reservation is held for the whole multipart stream, and the
            // stream writes the very file this loop just found, so a reserved
            // upload is a half-written one. The POST that owns it finishes it.
            guard !acceptingUploadIDs.contains(call.id) else { continue }
            let metadata = CallUploadMetadata.loadSidecar(nextTo: audioURL)
                ?? CallUploadMetadata(source: current.source, startedAt: current.startedAt, counterpartyName: current.counterpartyName)
            guard processingUploadIDs.insert(call.id).inserted else { continue }
            await process(uploadID: call.id, audioURL: audioURL, metadata: metadata, using: onAccepted)
        }
    }

    /// Runs until the containing app cancels the task. The app owns the task
    /// lifetime so it can hold a ProcessInfo activity while serving phones.
    public func run(host: String, identity: MacTLSIdentity) async throws {
        Task { await self.recoverStagedUploads() }
        let router = Router()
        let pairing = self.pairing
        router.get("health") { _, _ in
            SyncDTO.HealthReport(checks: ["server": true])
        }
        router.post("pair") { request, context async throws -> SyncDTO.PairResponse in
            let payload = try await request.decode(as: PairingRequest.self, context: context)
            do {
                return try await pairing.pair(payload)
            } catch let error as PairingError {
                throw HTTPError(.badRequest, message: error.localizedDescription)
            }
        }
        router.get("mirror") { request, _ async throws -> SyncDTO.Mirror in
            _ = try await Self.authorizedDevice(for: request, pairing: pairing)
            return try await self.mirror()
        }
        router.post("calls/:uploadID") { request, context async throws -> Response in
            _ = try await Self.authorizedDevice(for: request, pairing: pairing)
            guard let uploadID = UUID(uuidString: try context.parameters.require("uploadID")) else {
                throw HTTPError(.badRequest, message: "Expected a recording identifier.")
            }
            let contentType = request.headers[.contentType] ?? ""
            guard let boundary = contentType.split(separator: "boundary=").last.map(String.init), contentType.contains("multipart/form-data") else {
                throw HTTPError(.badRequest, message: "Expected multipart audio upload.")
            }
            let outcome = try await self.acceptUpload(uploadID: uploadID) {
                guard let upload = try await MultipartCallUpload.stream(
                    request.body,
                    boundary: boundary,
                    directory: self.receivedUploadsDirectory,
                    uploadID: uploadID
                ) else { throw HTTPError(.badRequest, message: "Malformed audio upload.") }
                return (upload.metadata, upload.audioURL)
            }
            guard outcome != .inProgress else {
                throw HTTPError(.conflict, message: "This recording is still being accepted.")
            }
            return Response(status: Self.responseStatus(for: outcome))
        }
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(key)
        )
        let app = Application(
            router: router,
            server: try .tls(.http1(), tlsConfiguration: tls),
            configuration: .init(address: .hostname(host, port: SyncConstants.serverPort))
        )
        try await app.runService()
    }

    func mirror() async throws -> SyncDTO.Mirror {
        try await Self.mirror(store: store)
    }

    enum UploadOutcome: Sendable, Equatable {
        case created
        case alreadyStored
        case resumed
        case inProgress
    }

    static func responseStatus(for outcome: UploadOutcome) -> HTTPResponse.Status {
        switch outcome {
        case .created: .created
        case .alreadyStored: .ok
        case .resumed: .accepted
        case .inProgress: .conflict
        }
    }

    /// Stores at most one call per upload identifier, so a phone that retries a
    /// transfer it could not acknowledge never produces a second call and never
    /// overwrites an already processed one.
    func accept(uploadID: UUID, metadata: CallUploadMetadata, audio: Data, fileExtension: String) async throws -> UploadOutcome {
        guard !audio.isEmpty else { throw HTTPError(.badRequest, message: "Audio upload is empty.") }
        return try await acceptUpload(uploadID: uploadID) {
            let audioURL = self.receivedUploadsDirectory
                .appendingPathComponent("\(uploadID.uuidString).\(MultipartCallUpload.safeAudioExtension(fileExtension))")
            try audio.write(to: audioURL, options: .atomic)
            return (metadata, audioURL)
        }
    }

    /// The one reserve -> settle -> stage -> accept -> unwind path. The route and
    /// the in-memory entry point differ only in how the audio reaches the staging
    /// directory, so the ordering the tests pin is the ordering the phone hits.
    private func acceptUpload(
        uploadID: UUID,
        stage: () async throws -> (metadata: CallUploadMetadata, audioURL: URL)
    ) async throws -> UploadOutcome {
        guard reserve(uploadID) else { return .inProgress }
        do {
            if let settled = await settleExistingUpload(uploadID) {
                release(uploadID)
                return settled
            }
            try FileManager.default.createDirectory(at: receivedUploadsDirectory, withIntermediateDirectories: true)
            let staged = try await stage()
            return try await acceptReserved(uploadID: uploadID, metadata: staged.metadata, audioURL: staged.audioURL)
        } catch {
            release(uploadID)
            throw error
        }
    }

    private func acceptReserved(uploadID: UUID, metadata: CallUploadMetadata, audioURL: URL) async throws -> UploadOutcome {
        defer { acceptingUploadIDs.remove(uploadID) }
        guard let existing = try await store.fetchCall(id: uploadID) else {
            return try await storeAccepted(uploadID: uploadID, metadata: metadata, audioURL: audioURL)
        }
        guard Self.isPhoneUpload(existing.source) else {
            throw HTTPError(.forbidden, message: "That recording is not a phone upload.")
        }
        if isProcessed(existing) {
            try? FileManager.default.removeItem(at: audioURL)
            return .alreadyStored
        }
        if processingUploadIDs.contains(uploadID) {
            try? FileManager.default.removeItem(at: audioURL)
            return .inProgress
        }
        var replaced = existing
        replaced.audioPath = audioURL.path
        try metadata.writeSidecar(nextTo: audioURL)
        try await store.upsertCall(replaced)
        launchProcessing(uploadID: uploadID, audioURL: audioURL, metadata: metadata)
        return .resumed
    }

    private func storeAccepted(uploadID: UUID, metadata: CallUploadMetadata, audioURL: URL) async throws -> UploadOutcome {
        try metadata.writeSidecar(nextTo: audioURL)
        let call = Call(
            id: uploadID,
            source: metadata.source,
            startedAt: metadata.startedAt ?? Date(),
            counterpartyName: metadata.counterpartyName,
            audioPath: audioURL.path,
            sttProvider: .appleSpeech,
            status: .uploaded
        )
        try await store.upsertCall(call)
        launchProcessing(uploadID: uploadID, audioURL: audioURL, metadata: metadata)
        return .created
    }

    /// Decides what an upload identifier that the Mac has already seen deserves.
    /// A finished call is acknowledged untouched; an accepted-but-unprocessed one
    /// resumes from its retained staging audio, so a 201 whose processing failed
    /// never leaves the recording stuck. `nil` means the bytes are still needed.
    private func settleExistingUpload(_ uploadID: UUID) async -> UploadOutcome? {
        guard let call = try? await store.fetchCall(id: uploadID) else { return nil }
        guard Self.isPhoneUpload(call.source) else { return nil }
        if isProcessed(call) { return .alreadyStored }
        if processingUploadIDs.contains(uploadID) { return .inProgress }
        guard let staged = stagedAudioURL(for: uploadID) else { return nil }
        let metadata = CallUploadMetadata.loadSidecar(nextTo: staged)
            ?? CallUploadMetadata(source: call.source, startedAt: call.startedAt, counterpartyName: call.counterpartyName)
        launchProcessing(uploadID: uploadID, audioURL: staged, metadata: metadata)
        return .resumed
    }

    private func launchProcessing(uploadID: UUID, audioURL: URL, metadata: CallUploadMetadata) {
        guard let onAccepted else { return }
        guard processingUploadIDs.insert(uploadID).inserted else { return }
        Task {
            await self.process(uploadID: uploadID, audioURL: audioURL, metadata: metadata, using: onAccepted)
        }
    }

    /// A processing failure after a 201 is recoverable here, not on the phone:
    /// the phone has already dropped its queued job, so the Mac keeps the
    /// staging audio, records the failure, and retries locally.
    private func process(
        uploadID: UUID,
        audioURL: URL,
        metadata: CallUploadMetadata,
        using onAccepted: @Sendable (UUID, URL, CallUploadMetadata) async throws -> Void
    ) async {
        for attempt in 0..<processingAttemptLimit {
            do {
                try await onAccepted(uploadID, audioURL, metadata)
                finishProcessing(uploadID)
                return
            } catch {
                await recordProcessingFailure(uploadID)
                guard attempt + 1 < processingAttemptLimit else { break }
                try? await Task.sleep(for: processingRetryDelay)
            }
        }
        finishProcessing(uploadID)
    }

    private func recordProcessingFailure(_ uploadID: UUID) async {
        guard var call = try? await store.fetchCall(id: uploadID), !isProcessed(call) else { return }
        // `.transcribed` already has segments; keep it so a later attempt
        // resumes notes instead of looking like a total failure.
        switch call.status {
        case .uploaded, .transcribing, .recording:
            call.status = .failed
            try? await store.upsertCall(call)
        case .transcribed, .notesReady, .failed:
            break
        }
    }

    private func finishProcessing(_ uploadID: UUID) {
        processingUploadIDs.remove(uploadID)
    }

    /// Only notes-ready is terminal. `.transcribed` means segments landed and
    /// notes still need to run, so a 201 whose notes stage threw stays eligible
    /// for `settleExistingUpload` / local retry.
    private static func isPhoneUpload(_ source: CallSource) -> Bool {
        switch source {
        case .iphoneRecording, .iphoneMeeting, .iphoneSpeaker: true
        case .macFaceTime, .macPhone, .macManual, .fileImport: false
        }
    }

    private func isProcessed(_ call: Call) -> Bool {
        switch call.status {
        case .notesReady: true
        case .recording, .uploaded, .transcribing, .transcribed, .failed: false
        }
    }

    /// Staging audio is keyed by upload identifier, so its presence is the
    /// durable record that a retry can resume without re-sending the recording.
    private func stagedAudioURL(for uploadID: UUID) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: receivedUploadsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.first {
            $0.deletingPathExtension().lastPathComponent == uploadID.uuidString && $0.pathExtension.lowercased() != "json"
        }
    }

    @discardableResult
    func reserve(_ uploadID: UUID) -> Bool {
        acceptingUploadIDs.insert(uploadID).inserted
    }

    func release(_ uploadID: UUID) {
        acceptingUploadIDs.remove(uploadID)
    }

    private static func authorizedDevice(for request: Request, pairing: PairingAuthority) async throws -> PairedDevice {
        guard let value = request.headers[.authorization], value.hasPrefix("Bearer "),
              let device = await pairing.authorize(token: String(value.dropFirst("Bearer ".count)))
        else { throw HTTPError(.unauthorized, message: "Pair this iPhone before syncing.") }
        return device
    }

    private static func mirror(store: any CallStore) async throws -> SyncDTO.Mirror {
        let calls = try await store.fetchCalls()
        let profiles = try await store.fetchSpeakerProfiles()
        var mirrored: [SyncDTO.MirroredCall] = []
        for call in calls {
            let note = try await store.fetchPreferredNotes(callID: call.id)
            let segments = try await store.fetchSegments(callID: call.id, provider: call.sttProvider)
            mirrored.append(SyncDTO.MirroredCall(
                id: call.id,
                title: note?.body.title ?? call.counterpartyName ?? "Call",
                summary: note?.body.summary ?? placeholderSummary(for: call.status),
                startedAt: call.startedAt,
                source: call.source.rawValue,
                status: call.status.rawValue,
                segments: try await mirroredSegments(segments, callID: call.id, profiles: profiles, store: store),
                note: note.map { .init(summary: $0.body.summary, decisions: $0.body.decisions, actionItems: $0.body.actionItems.map(\.text)) }
            ))
        }
        return SyncDTO.Mirror(calls: mirrored)
    }

    /// A call with no note yet still needs honest copy on the phone: a run that
    /// gave up must not keep reading as if it were still working.
    private static func placeholderSummary(for status: CallStatus) -> String {
        switch status {
        case .failed: "Could not finish this recording"
        case .transcribed: "Writing notes"
        case .recording, .uploaded, .transcribing, .notesReady: "Processing recording"
        }
    }

    private static func mirroredSegments(
        _ segments: [Segment],
        callID: UUID,
        profiles: [SpeakerProfile],
        store: any CallStore
    ) async throws -> [SyncDTO.MirroredSegment] {
        let speakers = try await store.fetchCallSpeakers(callID: callID)
        let turns = TurnAttributor.fromStored(segments: segments, speakers: speakers, profiles: profiles)
        return zip(segments, turns).map { segment, turn in
            .init(id: "\(callID.uuidString)-\(segment.seq)", speaker: turn.speakerName, text: segment.text, startSec: segment.startSec)
        }
    }
}

enum MultipartCallUpload {
    struct StagedUpload { var metadata: CallUploadMetadata; var audioURL: URL }

    static func safeAudioExtension(_ candidate: String) -> String {
        let normalized = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return ["wav", "m4a", "caf", "mp3", "aac", "aiff", "aif"].contains(normalized) ? normalized : "m4a"
    }

    static func stream(_ body: RequestBody, boundary: String, directory: URL, uploadID: UUID) async throws -> StagedUpload? {
        var parser = try MultipartStreamParser(boundary: boundary, directory: directory, uploadID: uploadID)
        defer { parser.abort() }
        for try await buffer in body {
            guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) else { continue }
            try parser.append(data)
        }
        return try parser.finish()
    }

}

struct MultipartStreamParser {
    private enum State: Equatable { case metadataHeaders, metadata, audioHeaders, audio, complete }
    private let headerEnd = Data("\r\n\r\n".utf8)
    private let partDelimiter: Data
    private let closingDelimiter: Data
    private let directory: URL
    private let uploadID: UUID
    private var state: State = .metadataHeaders
    private var buffer = Data()
    private var metadata: CallUploadMetadata?
    private var audioURL: URL?
    private var output: FileHandle?

    init(boundary: String, directory: URL, uploadID: UUID) throws {
        self.partDelimiter = Data("\r\n--\(boundary)".utf8)
        self.closingDelimiter = Data("\r\n--\(boundary)--".utf8)
        self.directory = directory
        self.uploadID = uploadID
    }

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        var progressed = true
        while progressed {
            progressed = false
            switch state {
            case .metadataHeaders:
                if let headers = consume(headerEnd) {
                    guard String(decoding: headers, as: UTF8.self).contains("name=\"metadata\"") else { throw CocoaError(.fileReadCorruptFile) }
                    state = .metadata
                    progressed = true
                }
            case .metadata:
                if let data = consume(partDelimiter) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    metadata = try decoder.decode(CallUploadMetadata.self, from: data)
                    state = .audioHeaders
                    progressed = true
                }
            case .audioHeaders:
                if let headers = consume(headerEnd) {
                    let text = String(decoding: headers, as: UTF8.self)
                    guard text.contains("name=\"audio\"") else { throw CocoaError(.fileReadCorruptFile) }
                    let filename = text.components(separatedBy: "filename=\"").dropFirst().first?.split(separator: "\"").first
                    let ext = MultipartCallUpload.safeAudioExtension(filename.map { URL(fileURLWithPath: String($0)).pathExtension } ?? "")
                    let url = directory.appendingPathComponent("\(uploadID.uuidString).\(ext)")
                    try? FileManager.default.removeItem(at: url)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    audioURL = url
                    output = try FileHandle(forWritingTo: url)
                    state = .audio
                    progressed = true
                }
            case .audio:
                if let range = buffer.range(of: closingDelimiter) {
                    try output?.write(contentsOf: buffer[..<range.lowerBound])
                    buffer.removeSubrange(..<range.upperBound)
                    state = .complete
                    progressed = true
                } else {
                    let retained = closingDelimiter.count - 1
                    if buffer.count > retained {
                        let count = buffer.count - retained
                        try output?.write(contentsOf: buffer.prefix(count))
                        buffer.removeFirst(count)
                    }
                }
            case .complete:
                break
            }
            if state != .audio, state != .complete, buffer.count > 1_048_576 { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    mutating func finish() throws -> MultipartCallUpload.StagedUpload? {
        guard state == .complete, let metadata, let audioURL,
              (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0
        else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            return nil
        }
        try output?.close()
        output = nil
        return .init(metadata: metadata, audioURL: audioURL)
    }

    mutating func abort() {
        try? output?.close()
        output = nil
        guard state != .complete, let audioURL else { return }
        try? FileManager.default.removeItem(at: audioURL)
    }

    private mutating func consume(_ delimiter: Data) -> Data? {
        guard let range = buffer.range(of: delimiter) else { return nil }
        let result = Data(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        return result
    }
}

#endif
