import Foundation

/// Realtime Meta Muse provider. Authentication is intentionally sent only in
/// the first JSON frame because the service ignores an HTTP Authorization
/// header on WebSocket connections.
public struct MetaRealtimeProvider: STTProvider {
    public let id: STTProviderID = .metaMuse
    public let supportsStreaming = true
    public let providesDiarization = true
    public let sendsAudioOffDevice = true

    public let configuration: MetaTranscriptionConfiguration
    public let endpoint: URL
    public let speakerStitching: MetaRealtimeSpeakerStitching?

    public init(
        configuration: MetaTranscriptionConfiguration,
        endpoint: URL = URL(string: "wss://api.meta.ai/v1/asr/realtime")!,
        speakerStitching: MetaRealtimeSpeakerStitching? = nil
    ) {
        self.configuration = configuration
        self.endpoint = endpoint
        self.speakerStitching = speakerStitching
    }

    public func healthCheck() async -> ProviderHealth {
        configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .unavailable(reason: "A Meta Model API key has not been configured")
            : .healthy
    }

    public func startSession(config: STTSessionConfig) async throws -> STTSession {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MetaTranscriptionError.missingAPIKey
        }
        let session = try MetaRealtimeSession(
            configuration: configuration,
            sessionConfig: config,
            endpoint: endpoint,
            speakerStitching: speakerStitching
        )
        try await session.start()
        return session
    }

    public func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] {
        try await MetaFileProvider(configuration: configuration).transcribe(fileURL: fileURL, config: config)
    }
}

struct MetaRealtimeSpeakerAudioWindow: Sendable {
    private struct Frame: Sendable {
        let startByte: Int
        let data: Data
    }

    private let byteLimit: Int
    private var frames: [Frame] = []
    private var byteCount = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    mutating func append(_ data: Data, endingAt endByte: Int) {
        guard !data.isEmpty else { return }
        let frame = Frame(startByte: endByte - data.count, data: data)
        frames.append(frame)
        byteCount += data.count
        trimToLimit()
    }

    func data(from startByte: Int, to endByte: Int) -> Data {
        guard endByte > startByte else { return Data() }
        var selected = Data()
        for frame in frames {
            let frameEnd = frame.startByte + frame.data.count
            let lower = max(startByte, frame.startByte)
            let upper = min(endByte, frameEnd)
            guard upper > lower else { continue }
            let offset = lower - frame.startByte
            selected.append(frame.data.subdata(in: offset..<(offset + upper - lower)))
        }
        return selected
    }

    private mutating func trimToLimit() {
        while byteCount > byteLimit, let first = frames.first {
            let overflow = byteCount - byteLimit
            if first.data.count <= overflow {
                frames.removeFirst()
                byteCount -= first.data.count
            } else {
                let retained = first.data.subdata(in: overflow..<first.data.count)
                frames[0] = Frame(startByte: first.startByte + overflow, data: retained)
                byteCount -= overflow
            }
        }
    }
}

/// A real-time session maintains protocol state by `turnId`, because the API
/// permits a later turn to begin before an earlier speechComplete arrives.
public actor MetaRealtimeSession: STTSession {
    public nonisolated let results: AsyncThrowingStream<RawSegment, Error>
    private let continuation: AsyncThrowingStream<RawSegment, Error>.Continuation
    private let configuration: MetaTranscriptionConfiguration
    private let sessionConfig: STTSessionConfig
    private let endpoint: URL
    private let speakerStitching: MetaRealtimeSpeakerStitching?

    private var socket: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var sessionID: String?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var sessionAudioBytes = 0
    private var logicalAudioBytes = 0
    private var sessionTimelineOffset = 0.0
    private var sessionMaximumProcessedMilliseconds = 0
    private var completedBilledSeconds = 0
    private var replayBuffer: [Data] = []
    private var replayBufferBytes = 0
    private var eventReducer = MetaRealtimeEventReducer(timelineOffset: 0)
    private var finalizedHistory: [RawSegment] = []
    private var resampler: MetaPCMResampler
    private var sessionSpeakerTags: [String: String] = [:]
    private var speakerAudio = MetaRealtimeSpeakerAudioWindow(
        byteLimit: 30 * MetaAudioFormat.pcm24KHz.byteRate
    )
    private var turnAudioStarts: [Int: Int] = [:]
    private var latestTurnID: Int?
    private var crossSessionSpeakerEmbeddings: [UUID: [Float]] = [:]
    private var ingress: Task<Void, Error>?
    private var finished = false

    /// Reconnect before Meta's 60-minute limit, preserving five seconds of
    /// mixed PCM to cover a boundary. The new session gets a new server ID.
    public static let reconnectAudioBytes = 55 * 60 * MetaAudioFormat.pcm24KHz.byteRate
    private static let replayBytesLimit = 5 * MetaAudioFormat.pcm24KHz.byteRate

    init(
        configuration: MetaTranscriptionConfiguration,
        sessionConfig: STTSessionConfig,
        endpoint: URL,
        speakerStitching: MetaRealtimeSpeakerStitching? = nil
    ) throws {
        self.configuration = configuration
        self.sessionConfig = sessionConfig
        self.endpoint = endpoint
        self.speakerStitching = speakerStitching
        self.resampler = try MetaPCMResampler(inputSampleRate: sessionConfig.sampleRate)
        let stream = AsyncThrowingStream<RawSegment, Error>.makeStream()
        self.results = stream.stream
        self.continuation = stream.continuation
    }

    deinit {
        receiverTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func start() async throws {
        try await connect(timelineOffset: 0, replay: [])
    }

    /// PCM ingress is serialized through a chained task because the capture
    /// path issues overlapping appends; an append must never interleave with
    /// another append or with a reconnect handshake and its replay.
    public func append(pcm: Data) async throws {
        guard !finished, !pcm.isEmpty else { return }
        let metaPCM = resampler.convert(pcm)
        guard !metaPCM.isEmpty else { return }
        let previous = ingress
        let task = Task {
            try? await previous?.value
            try await self.ingest(metaPCM)
        }
        ingress = task
        try await task.value
    }

    private func ingest(_ metaPCM: Data) async throws {
        if sessionAudioBytes + metaPCM.count > Self.reconnectAudioBytes {
            try await reconnect()
        }
        logicalAudioBytes += metaPCM.count
        try await sendPaced(metaPCM)
        retainForReplay(metaPCM)
    }

    /// Capture feeds zero PCM during live silence. This explicit helper makes
    /// that requirement discoverable and keeps an otherwise idle socket alive.
    public func appendSilence(milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        let bytes = sessionConfig.sampleRate * MetaAudioFormat.pcm24KHz.bytesPerSample * milliseconds / 1_000
        try await append(pcm: Data(count: bytes - (bytes % 2)))
    }

    public func finish() async throws {
        guard !finished else { return }
        finished = true
        try? await ingress?.value
        do {
            try await socket?.send(.string("{\"type\":\"endStream\"}"))
            await receiverTask?.value
            closeCurrentAccounting()
            continuation.finish()
        } catch let error as MetaTranscriptionError {
            closeCurrentAccounting()
            continuation.finish(throwing: error)
            throw error
        } catch {
            let wrapped = classifySocketError(error)
            closeCurrentAccounting()
            continuation.finish(throwing: wrapped)
            throw wrapped
        }
    }

    /// Total service-billed seconds observed from audio progress, suitable for
    /// persisting directly to `calls.meta_billed_sec`.
    public func billedSeconds() -> Int {
        completedBilledSeconds + MetaCostMeter.billedSeconds(
            audioProcessedMilliseconds: sessionMaximumProcessedMilliseconds
        )
    }

    private func connect(timelineOffset: TimeInterval, replay: [Data]) async throws {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "sessionId", value: "callnotes-\(UUID().uuidString)"),
        ]
        guard let url = components?.url else {
            throw MetaTranscriptionError.unexpectedResponse("The Meta realtime endpoint is invalid")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        socket = task
        sessionTimelineOffset = timelineOffset
        sessionAudioBytes = 0
        sessionMaximumProcessedMilliseconds = 0
        sessionStartedAt = ContinuousClock.now
        finalizedHistory.removeAll { $0.end <= timelineOffset - 5 }
        eventReducer = MetaRealtimeEventReducer(timelineOffset: timelineOffset, finalized: finalizedHistory)
        sessionSpeakerTags.removeAll(keepingCapacity: true)
        speakerAudio.reset()
        turnAudioStarts.removeAll(keepingCapacity: true)
        latestTurnID = nil

        let handshake = MetaRealtimeHandshake(
            authorization: .init(accessToken: "Bearer \(configuration.apiKey)"),
            audioEncoding: "PCM_24KHZ",
            model: MetaTranscriptionConfiguration.modelID,
            mode: "DIARIZATION",
            partialMode: "CUMULATIVE",
            emitAudioProgress: true,
            keywords: configuration.keywords + sessionConfig.customVocabulary,
            languageBias: configuration.languageBias,
            zdrOverride: configuration.zeroDataRetention
        )
        do {
            let encoded = try JSONEncoder().encode(handshake)
            try await task.send(.string(String(decoding: encoded, as: UTF8.self)))
            let acknowledgement = try await task.receive()
            guard case let .string(text) = acknowledgement,
                let ack = try? JSONDecoder().decode(MetaRealtimeAcknowledgement.self, from: Data(text.utf8))
            else {
                throw MetaTranscriptionError.unexpectedResponse("Meta did not acknowledge the realtime handshake")
            }
            if let message = ack.error?.message {
                throw MetaTranscriptionError.backend(message)
            }
            guard ack.type == nil, !ack.sessionId.isEmpty else {
                throw MetaTranscriptionError.unexpectedResponse("Meta did not acknowledge the realtime handshake")
            }
            sessionID = ack.sessionId
            receiverTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            for pcm in replay {
                try await sendPaced(pcm)
            }
        } catch let error as MetaTranscriptionError {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw classifySocketError(error)
        }
    }

    private func reconnect() async throws {
        closeCurrentAccounting()
        receiverTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        let replay = replayBuffer
        let replayDuration = Double(replayBufferBytes) / Double(MetaAudioFormat.pcm24KHz.byteRate)
        let logicalDuration = Double(logicalAudioBytes) / Double(MetaAudioFormat.pcm24KHz.byteRate)
        try await connect(timelineOffset: max(0, logicalDuration - replayDuration), replay: replay)
    }

    private func sendPaced(_ pcm: Data) async throws {
        guard let socket, let sessionStartedAt else {
            throw MetaTranscriptionError.transport("The Meta realtime session is not connected")
        }
        let prospectiveBytes = sessionAudioBytes + pcm.count
        let elapsed = sessionStartedAt.duration(to: ContinuousClock.now).components
        let elapsedNanoseconds = Int64(elapsed.seconds) * 1_000_000_000 + Int64(elapsed.attoseconds / 1_000_000_000)
        let delay = MetaRealtimePacing.requiredSleepNanoseconds(
            sentAudioBytes: prospectiveBytes,
            elapsedNanoseconds: elapsedNanoseconds
        )
        if delay > 0 {
            try await Task.sleep(for: .nanoseconds(delay))
        }
        try await socket.send(.data(pcm))
        sessionAudioBytes = prospectiveBytes
        speakerAudio.append(pcm, endingAt: sessionAudioBytes)
    }

    private func retainForReplay(_ pcm: Data) {
        replayBuffer.append(pcm)
        replayBufferBytes += pcm.count
        while replayBufferBytes > Self.replayBytesLimit, let first = replayBuffer.first {
            replayBuffer.removeFirst()
            replayBufferBytes -= first.count
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard case let .string(text) = message else { continue }
                try await handle(event: MetaRealtimeEvent.decode(text))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !finished, !Task.isCancelled, socket === self.socket else { return }
            let wrapped = classifySocketError(error)
            continuation.finish(throwing: wrapped)
        }
    }

    private func handle(event: MetaRealtimeEvent) async throws {
        if event.type == "speechStart", let turnID = event.turnId {
            latestTurnID = turnID
            turnAudioStarts[turnID] = audioByteOffset(for: event.audioProcessedMs)
        }
        var resolvedEvent = event
        if event.type == "speaker", let label = event.label,
            let stitching = speakerStitching
        {
            if let stitched = sessionSpeakerTags[label] {
                resolvedEvent.label = stitched
            } else {
                let turnID = event.turnId ?? latestTurnID
                let startByte = turnID.flatMap { turnAudioStarts[$0] }
                    ?? max(0, sessionAudioBytes - 30 * MetaAudioFormat.pcm24KHz.byteRate)
                let pcm = speakerAudio.data(
                    from: startByte,
                    to: audioByteOffset(for: event.audioProcessedMs)
                )
                if let speakerTag = await stitchedSpeakerTag(using: stitching, pcm: pcm) {
                    sessionSpeakerTags[label] = speakerTag
                    resolvedEvent.label = speakerTag
                }
            }
        }
        if let segment = try eventReducer.consume(event: resolvedEvent) {
            if !segment.isVolatile { finalizedHistory.append(segment) }
            continuation.yield(segment)
        }
        sessionMaximumProcessedMilliseconds = max(
            sessionMaximumProcessedMilliseconds,
            eventReducer.maximumAudioProcessedMilliseconds
        )
    }

    private func audioByteOffset(for processedMilliseconds: Int?) -> Int {
        guard let processedMilliseconds else { return sessionAudioBytes }
        let bytes = processedMilliseconds * MetaAudioFormat.pcm24KHz.byteRate / 1_000
        return min(sessionAudioBytes, max(0, bytes))
    }

    private func stitchedSpeakerTag(
        using stitching: MetaRealtimeSpeakerStitching,
        pcm: Data
    ) async -> String? {
        guard let embedding = await stitching.embedding(for: pcm) else { return nil }
        if let profileID = stitching.profileID(for: embedding) {
            return profileID.uuidString
        }
        let existingProfiles = crossSessionSpeakerEmbeddings.map { id, centroid in
            SpeakerProfile(
                id: id,
                displayName: id.uuidString,
                centroid: centroid,
                embeddingModel: EmbeddingModel.weSpeakerV2
            )
        }
        switch SpeakerMatcher.match(embedding: embedding, against: existingProfiles) {
        case let .autoLabel(profileID, _), let .suggest(profileID, _):
            return profileID.uuidString
        case .unknown:
            let id = UUID()
            crossSessionSpeakerEmbeddings[id] = embedding
            return id.uuidString
        }
    }

    private func closeCurrentAccounting() {
        completedBilledSeconds += MetaCostMeter.billedSeconds(
            audioProcessedMilliseconds: sessionMaximumProcessedMilliseconds
        )
        sessionMaximumProcessedMilliseconds = 0
    }

    private func classifySocketError(_ error: Error) -> MetaTranscriptionError {
        let closeCode = socket?.closeCode
        if closeCode?.rawValue == 1_013 {
            return MetaTranscriptionError.quotaExceeded("Meta rate limited this realtime session")
        }
        switch closeCode {
        case .policyViolation:
            return MetaTranscriptionError.streamingPolicy("Meta rejected realtime pacing or request policy")
        case .internalServerError:
            return MetaTranscriptionError.backend("Meta realtime service failed")
        default:
            return MetaTranscriptionError.transport(error.localizedDescription)
        }
    }
}

private struct MetaRealtimeHandshake: Encodable {
    struct Authorization: Encodable { let accessToken: String }
    let authorization: Authorization
    let audioEncoding: String
    let model: String
    let mode: String
    let partialMode: String
    let emitAudioProgress: Bool
    let keywords: [String]
    let languageBias: [String]
    let zdrOverride: Bool
}

private struct MetaRealtimeAcknowledgement: Decodable {
    let sessionId: String
    let type: String?
    let error: ErrorBody?

    struct ErrorBody: Decodable { let message: String }
}

struct MetaRealtimeEvent: Decodable {
    let type: String?
    let turnId: Int?
    let transcript: String?
    let final: Bool?
    let audioProcessedMs: Int?
    var label: String?
    let message: String?

    static func decode(_ text: String) throws -> MetaRealtimeEvent {
        do {
            return try JSONDecoder().decode(MetaRealtimeEvent.self, from: Data(text.utf8))
        } catch {
            throw MetaTranscriptionError.unexpectedResponse("Meta returned an invalid realtime event")
        }
    }
}

/// Deterministic conversion of Meta's JSON event stream to CallNotes segments.
/// Fixture tests cover cumulative partials, overlapping turns, speaker events,
/// and final-result de-duplication without a WebSocket or an API key.
public struct MetaRealtimeEventReducer: Sendable {
    private let timelineOffset: TimeInterval
    private var turnStarts: [Int: TimeInterval] = [:]
    private var turnSpeakers: [Int: String] = [:]
    private var latestTurnID: Int?
    private var finalized: [RawSegment] = []
    public private(set) var maximumAudioProcessedMilliseconds = 0

    public init(timelineOffset: TimeInterval, finalized: [RawSegment] = []) {
        self.timelineOffset = timelineOffset
        self.finalized = finalized
    }

    public mutating func consume(json: String) throws -> RawSegment? {
        try consume(event: MetaRealtimeEvent.decode(json))
    }

    mutating func consume(event: MetaRealtimeEvent) throws -> RawSegment? {
        if let message = event.message, event.type == "error" {
            throw MetaTranscriptionError.backend(message)
        }
        if let processed = event.audioProcessedMs {
            maximumAudioProcessedMilliseconds = max(maximumAudioProcessedMilliseconds, processed)
        }
        switch event.type {
        case "speechStart":
            guard let turnID = event.turnId else { return nil }
            turnStarts[turnID] = timelineOffset + Double(event.audioProcessedMs ?? 0) / 1_000
            latestTurnID = turnID
            return nil
        case "speaker":
            if let turnID = event.turnId ?? latestTurnID, let label = event.label { turnSpeakers[turnID] = label }
            return nil
        case "transcript":
            guard let text = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            let turnID = event.turnId ?? latestTurnID
            let start = turnID.flatMap { turnStarts[$0] } ?? timelineOffset
            let end = timelineOffset + Double(event.audioProcessedMs ?? 0) / 1_000
            return RawSegment(
                start: start,
                end: max(start, end),
                text: text,
                speakerTag: turnID.flatMap { turnSpeakers[$0] },
                channel: .mixed,
                isVolatile: event.final != true
            )
        case "speechComplete":
            guard let turnID = event.turnId,
                let text = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let start = turnStarts.removeValue(forKey: turnID) ?? timelineOffset
            let end = timelineOffset + Double(event.audioProcessedMs ?? 0) / 1_000
            let segment = RawSegment(
                start: start,
                end: max(start, end),
                text: text,
                speakerTag: turnSpeakers.removeValue(forKey: turnID),
                channel: .mixed
            )
            guard !isDuplicateFinal(segment) else { return nil }
            finalized.append(segment)
            return segment
        default:
            return nil // Unknown event types are explicitly additive in the API.
        }
    }

    private func isDuplicateFinal(_ candidate: RawSegment) -> Bool {
        finalized.contains { existing in
            existing.start < candidate.end && candidate.start < existing.end
                && normalized(existing.text) == normalized(candidate.text)
        }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
