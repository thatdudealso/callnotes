import Foundation
import Testing

@testable import CallNotesCore

/// These tests intentionally do nothing unless the captain explicitly enables
/// `CALLNOTES_META=1` and supplies a short, mono 16-bit 24 kHz WAV fixture.
/// That keeps normal developer and CI runs free of cloud calls and charges.
@Suite(.serialized) struct MetaLiveIntegrationTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test func fileEndpointReturnsTranscriptAndWholeSecondReceipt() async throws {
        guard let fixtureURL = fixtureURL, let apiKey = environment["META_MODEL_API_KEY"] else { return }

        let result = try await MetaFileProvider(
            configuration: MetaTranscriptionConfiguration(apiKey: apiKey)
        ).transcribeWithReceipt(fileURL: fixtureURL, config: STTSessionConfig())

        #expect(!result.segments.isEmpty)
        #expect(result.billedSeconds > 0)
    }

    @Test func realtimeReturnsPartialsOrFinalsAtRealtimePaceAndAccountsForAudio() async throws {
        guard let fixtureURL = fixtureURL, let apiKey = environment["META_MODEL_API_KEY"] else { return }
        let wav = try MetaWAV.read(fileURL: fixtureURL)
        let provider = MetaRealtimeProvider(configuration: MetaTranscriptionConfiguration(apiKey: apiKey))
        let session = try await provider.startSession(config: STTSessionConfig(sampleRate: wav.sampleRate))
        let collector = Task<[RawSegment], Error> {
            var output: [RawSegment] = []
            for try await segment in session.results { output.append(segment) }
            return output
        }
        let frameBytes = MetaAudioFormat.pcm24KHz.byteRate * 80 / 1_000
        for offset in stride(from: 0, to: wav.pcm.count, by: frameBytes) {
            let end = min(offset + frameBytes, wav.pcm.count)
            try await session.append(pcm: wav.pcm.subdata(in: offset..<end))
        }
        try await session.finish()
        let segments = try await collector.value

        #expect(!segments.isEmpty)
        #expect(segments.contains { !$0.isVolatile })
        let realtime = try #require(session as? MetaRealtimeSession)
        #expect(await realtime.billedSeconds() > 0)
    }

    @Test func invalidMetaHandshakeFallsBackToLocalWithoutSendingAudio() async throws {
        guard environment["CALLNOTES_META"] == "1" else { return }
        let fallback = LocalProbeProvider()
        let provider = MetaFallbackProvider(
            meta: MetaRealtimeProvider(configuration: MetaTranscriptionConfiguration(apiKey: "invalid-key")),
            local: fallback
        )

        let session = try await provider.startSession(config: STTSessionConfig())
        #expect(session is LocalProbeSession)
    }

    /// Enable only for an intentional pennies-level acceptance run. The long
    /// fixture is synthetic and proves both real multipart requests complete.
    @Test func longSyntheticFileUsesTheRealChunkingPath() async throws {
        guard environment["CALLNOTES_META_LONG"] == "1",
            let path = environment["CALLNOTES_META_LONG_FIXTURE_WAV"],
            let apiKey = environment["META_MODEL_API_KEY"]
        else { return }
        let result = try await MetaFileProvider(
            configuration: MetaTranscriptionConfiguration(apiKey: apiKey)
        ).transcribeWithReceipt(fileURL: URL(fileURLWithPath: path), config: STTSessionConfig())
        #expect(result.billedSeconds >= 600)
    }

    private var fixtureURL: URL? {
        guard environment["CALLNOTES_META"] == "1",
            let path = environment["CALLNOTES_META_FIXTURE_WAV"]
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

private struct LocalProbeProvider: STTProvider {
    let id: STTProviderID = .appleSpeech
    let supportsStreaming = true
    let providesDiarization = false
    let sendsAudioOffDevice = false

    func startSession(config: STTSessionConfig) async throws -> STTSession { LocalProbeSession() }
    func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] { [] }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private actor LocalProbeSession: STTSession {
    nonisolated let results: AsyncThrowingStream<RawSegment, Error>
    private let continuation: AsyncThrowingStream<RawSegment, Error>.Continuation

    init() {
        let stream = AsyncThrowingStream<RawSegment, Error>.makeStream()
        results = stream.stream
        continuation = stream.continuation
    }

    func append(pcm: Data) async throws {}
    func finish() async throws { continuation.finish() }
}
