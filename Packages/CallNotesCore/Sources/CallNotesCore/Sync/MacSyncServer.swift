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
    private let onAccepted: (@Sendable (UUID, URL, CallUploadMetadata) async -> Void)?
    private var acceptingUploadIDs: Set<UUID> = []

    public init(
        pairing: PairingAuthority = PairingAuthority(),
        store: any CallStore = MemoryStore(),
        receivedUploadsDirectory: URL? = nil,
        onAccepted: (@Sendable (UUID, URL, CallUploadMetadata) async -> Void)? = nil
    ) {
        self.pairing = pairing
        self.store = store
        self.receivedUploadsDirectory = receivedUploadsDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("CallNotesPhoneUploads", isDirectory: true)
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

    /// Runs until the containing app cancels the task. The app owns the task
    /// lifetime so it can hold a ProcessInfo activity while serving phones.
    public func run(host: String, identity: MacTLSIdentity) async throws {
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
            return try await Self.mirror(store: self.store)
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
            guard await self.reserve(uploadID) else {
                throw HTTPError(.conflict, message: "This recording is still being accepted.")
            }
            if await self.hasStoredCall(uploadID) {
                await self.release(uploadID)
                return Response(status: .ok)
            }
            do {
                try FileManager.default.createDirectory(at: self.receivedUploadsDirectory, withIntermediateDirectories: true)
                guard let upload = try await MultipartCallUpload.stream(
                    request.body,
                    boundary: boundary,
                    directory: self.receivedUploadsDirectory,
                    uploadID: uploadID
                ) else { throw HTTPError(.badRequest, message: "Malformed audio upload.") }
                let outcome = try await self.acceptReserved(uploadID: uploadID, metadata: upload.metadata, audioURL: upload.audioURL)
                return Response(status: outcome == .created ? .created : .ok)
            } catch {
                await self.release(uploadID)
                throw error
            }
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

    enum UploadOutcome: Sendable, Equatable {
        case created
        case alreadyStored
        case inProgress
    }

    /// Stores at most one call per upload identifier, so a phone that retries a
    /// transfer it could not acknowledge never produces a second call and never
    /// overwrites an already processed one.
    func accept(uploadID: UUID, metadata: CallUploadMetadata, audio: Data, fileExtension: String) async throws -> UploadOutcome {
        guard reserve(uploadID) else { return .inProgress }
        do {
            try FileManager.default.createDirectory(at: receivedUploadsDirectory, withIntermediateDirectories: true)
            let audioURL = receivedUploadsDirectory.appendingPathComponent("\(uploadID.uuidString).\(MultipartCallUpload.safeAudioExtension(fileExtension))")
            try audio.write(to: audioURL, options: .atomic)
            return try await acceptReserved(uploadID: uploadID, metadata: metadata, audioURL: audioURL)
        } catch {
            release(uploadID)
            throw error
        }
    }

    private func acceptReserved(uploadID: UUID, metadata: CallUploadMetadata, audioURL: URL) async throws -> UploadOutcome {
        defer { acceptingUploadIDs.remove(uploadID) }
        if try await store.fetchCall(id: uploadID) != nil { return .alreadyStored }
        return try await storeAccepted(uploadID: uploadID, metadata: metadata, audioURL: audioURL)
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
        if let onAccepted {
            Task { await onAccepted(uploadID, audioURL, metadata) }
        }
        return .created
    }

    private func reserve(_ uploadID: UUID) -> Bool {
        acceptingUploadIDs.insert(uploadID).inserted
    }

    private func release(_ uploadID: UUID) {
        acceptingUploadIDs.remove(uploadID)
    }

    private func hasStoredCall(_ uploadID: UUID) async -> Bool {
        (try? await store.fetchCall(id: uploadID)) != nil
    }

    private static func authorizedDevice(for request: Request, pairing: PairingAuthority) async throws -> PairedDevice {
        guard let value = request.headers[.authorization], value.hasPrefix("Bearer "),
              let device = await pairing.authorize(token: String(value.dropFirst("Bearer ".count)))
        else { throw HTTPError(.unauthorized, message: "Pair this iPhone before syncing.") }
        return device
    }

    private static func mirror(store: any CallStore) async throws -> SyncDTO.Mirror {
        let calls = try await store.fetchCalls()
        var mirrored: [SyncDTO.MirroredCall] = []
        for call in calls {
            let note = try await store.fetchPreferredNotes(callID: call.id)
            let segments = try await store.fetchSegments(callID: call.id, provider: call.sttProvider)
            mirrored.append(SyncDTO.MirroredCall(
                id: call.id,
                title: note?.body.title ?? call.counterpartyName ?? "Call",
                summary: note?.body.summary ?? "Processing recording",
                startedAt: call.startedAt,
                source: call.source.rawValue,
                status: call.status.rawValue,
                segments: try await mirroredSegments(segments, callID: call.id, store: store),
                note: note.map { .init(summary: $0.body.summary, decisions: $0.body.decisions, actionItems: $0.body.actionItems.map(\.text)) }
            ))
        }
        return SyncDTO.Mirror(calls: mirrored)
    }

    private static func mirroredSegments(_ segments: [Segment], callID: UUID, store: any CallStore) async throws -> [SyncDTO.MirroredSegment] {
        let speakers = try await store.fetchCallSpeakers(callID: callID)
        let profiles = try await store.fetchSpeakerProfiles()
        let turns = TurnAttributor.fromStored(segments: segments, speakers: speakers, profiles: profiles)
        return zip(segments, turns).map { segment, turn in
            .init(id: "\(callID.uuidString)-\(segment.seq)", speaker: turn.speakerName, text: segment.text, startSec: segment.startSec)
        }
    }
}

enum MultipartCallUpload {
    struct Upload { var metadata: CallUploadMetadata; var audio: Data; var fileExtension: String }
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

    static func parseFile(_ url: URL, boundary: String, directory: URL, uploadID: UUID) throws -> StagedUpload? {
        let headerEnd = Data("\r\n\r\n".utf8)
        let partDelimiter = Data("\r\n--\(boundary)".utf8)
        var reader = try MultipartFileReader(url: url)
        defer { try? reader.close() }
        guard let metadataHeaders = try reader.readUntil(headerEnd),
              String(decoding: metadataHeaders, as: UTF8.self).contains("name=\"metadata\""),
              let metadataData = try reader.readUntil(partDelimiter)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(CallUploadMetadata.self, from: metadataData)
        guard let audioHeaders = try reader.readUntil(headerEnd) else { return nil }
        let headers = String(decoding: audioHeaders, as: UTF8.self)
        guard headers.contains("name=\"audio\"") else { return nil }
        let filename = headers.components(separatedBy: "filename=\"").dropFirst().first?.split(separator: "\"").first
        let fileExtension = safeAudioExtension(filename.map { URL(fileURLWithPath: String($0)).pathExtension } ?? "")
        let audioURL = directory.appendingPathComponent("\(uploadID.uuidString).\(fileExtension)")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: audioURL)
        defer { try? output.close() }
        guard try reader.copyUntil(Data("\r\n--\(boundary)--".utf8), to: output) else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        return StagedUpload(metadata: metadata, audioURL: audioURL)
    }
    static func parse(_ body: Data, boundary: String) throws -> Upload? {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        let metadataDecoder = JSONDecoder(); metadataDecoder.dateDecodingStrategy = .iso8601
        var metadata: CallUploadMetadata?
        var audio: Data?
        var fileExtension = "m4a"
        for part in body.multipartParts(separatedBy: delimiter) {
            guard let headerRange = part.range(of: headerEnd) else { continue }
            let headers = String(decoding: part[..<headerRange.lowerBound], as: UTF8.self)
            let content = Data(part[headerRange.upperBound...]).removingTrailingFramingCRLF()
            if headers.contains("name=\"metadata\"") { metadata = try metadataDecoder.decode(CallUploadMetadata.self, from: content) }
            if headers.contains("name=\"audio\"") {
                audio = content
                if let filename = headers.components(separatedBy: "filename=\"").dropFirst().first?.split(separator: "\"").first {
                    fileExtension = URL(fileURLWithPath: String(filename)).pathExtension.lowercased()
                }
            }
        }
        guard let metadata, let audio, !audio.isEmpty else { return nil }
        return Upload(metadata: metadata, audio: audio, fileExtension: fileExtension.isEmpty ? "m4a" : fileExtension)
    }
}

private struct MultipartStreamParser {
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

    mutating func close() throws { try output?.close() }

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

private struct MultipartFileReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }

    mutating func close() throws { try handle.close() }

    mutating func readUntil(_ delimiter: Data) throws -> Data? {
        while true {
            if let range = buffer.range(of: delimiter) {
                let result = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return result
            }
            guard try fill(), buffer.count <= 1_048_576 else { return nil }
        }
    }

    mutating func copyUntil(_ delimiter: Data, to output: FileHandle) throws -> Bool {
        while true {
            if let range = buffer.range(of: delimiter) {
                try output.write(contentsOf: buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return true
            }
            let retained = max(0, delimiter.count - 1)
            if buffer.count > retained {
                let count = buffer.count - retained
                try output.write(contentsOf: buffer.prefix(count))
                buffer.removeFirst(count)
            }
            guard try fill() else { return false }
        }
    }

    private mutating func fill() throws -> Bool {
        guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
        buffer.append(chunk)
        return true
    }
}

private extension Data {
    func removingTrailingFramingCRLF() -> Data {
        guard count >= 2, suffix(2) == Data("\r\n".utf8) else { return self }
        return Data(dropLast(2))
    }
}

private extension Data {
    func multipartParts(separatedBy delimiter: Data) -> [Data] {
        var parts: [Data] = []
        var start = startIndex
        while let range = range(of: delimiter, options: [], in: start..<endIndex) {
            if start != range.lowerBound { parts.append(Data(self[start..<range.lowerBound])) }
            start = range.upperBound
        }
        if start < endIndex { parts.append(Data(self[start..<endIndex])) }
        return parts
    }
}
#endif
