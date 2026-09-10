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
            return try await pairing.pair(payload)
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
            let buffer = try await request.body.collect(upTo: .max)
            guard let body = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
                  let upload = try MultipartCallUpload.parse(body, boundary: boundary)
            else { throw HTTPError(.badRequest, message: "Malformed audio upload.") }
            let outcome = try await self.accept(
                uploadID: uploadID,
                metadata: upload.metadata,
                audio: upload.audio,
                fileExtension: upload.fileExtension
            )
            return Response(status: outcome == .created ? .created : .ok)
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
    }

    /// Stores at most one call per upload identifier, so a phone that retries a
    /// transfer it could not acknowledge never produces a second call and never
    /// overwrites an already processed one.
    func accept(uploadID: UUID, metadata: CallUploadMetadata, audio: Data, fileExtension: String) async throws -> UploadOutcome {
        if try await store.fetchCall(id: uploadID) != nil { return .alreadyStored }
        try FileManager.default.createDirectory(at: receivedUploadsDirectory, withIntermediateDirectories: true)
        let audioURL = receivedUploadsDirectory.appendingPathComponent("\(uploadID.uuidString).\(fileExtension)")
        try audio.write(to: audioURL, options: .atomic)
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
            await onAccepted(uploadID, audioURL, metadata)
        }
        return .created
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
                segments: segments.map { .init(id: "\(call.id.uuidString)-\($0.seq)", speaker: $0.channel.rawValue.capitalized, text: $0.text, startSec: $0.startSec) },
                note: note.map { .init(summary: $0.body.summary, decisions: $0.body.decisions, actionItems: $0.body.actionItems.map(\.text)) }
            ))
        }
        return SyncDTO.Mirror(calls: mirrored)
    }
}

private enum MultipartCallUpload {
    struct Upload { var metadata: CallUploadMetadata; var audio: Data; var fileExtension: String }
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
            let content = Data(part[headerRange.upperBound...]).trimmingCRLF()
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

private extension Data {
    func trimmingCRLF() -> Data {
        var start = startIndex; var end = endIndex
        while start < end, self[start] == 13 || self[start] == 10 { formIndex(after: &start) }
        while start < end, self[index(before: end)] == 13 || self[index(before: end)] == 10 { formIndex(before: &end) }
        return Data(self[start..<end])
    }
}

private extension Data {
    func multipartParts(separatedBy delimiter: Data) -> [Data] {
        var parts: [Data] = []
        var start = startIndex
        while let range = range(of: delimiter, options: [], in: start..<endIndex) {
            if start != range.lowerBound { parts.append(Data(self[start..<range.lowerBound]).trimmingCRLF()) }
            start = range.upperBound
        }
        if start < endIndex { parts.append(Data(self[start..<endIndex]).trimmingCRLF()) }
        return parts
    }
}
#endif
