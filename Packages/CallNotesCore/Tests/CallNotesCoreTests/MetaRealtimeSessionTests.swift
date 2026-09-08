import Foundation
import Network
import Testing

@testable import CallNotesCore

/// Loopback WebSocket server speaking just enough of the Meta realtime
/// protocol (handshake acknowledgement, server-push events) to exercise
/// `MetaRealtimeSession` without the live API or an API key.
private final class LoopbackMetaRealtimeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-meta-realtime-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    private init() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
        listener.start(queue: queue)
    }

    static func started() async throws -> LoopbackMetaRealtimeServer {
        let server = try LoopbackMetaRealtimeServer()
        for _ in 0..<250 {
            if let port = server.listener.port?.rawValue, port != 0 { return server }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MetaTranscriptionError.transport("The loopback server did not become ready")
    }

    var endpoint: URL {
        URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    /// Push a server event on an accepted connection (0-based, accept order).
    func send(_ text: String, toConnection index: Int) async throws {
        let connection = try await acceptedConnection(at: index)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "event", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func connection(at index: Int) -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections.count > index ? connections[index] : nil
    }

    private func acceptedConnection(at index: Int) async throws -> NWConnection {
        for _ in 0..<250 {
            if let connection = connection(at: index) { return connection }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MetaTranscriptionError.transport("Connection \(index) was never accepted")
    }

    private func adopt(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receiveNext(on: connection, acknowledged: false)
    }

    private func receiveNext(on connection: NWConnection, acknowledged: Bool) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            var acknowledged = acknowledged
            let isText = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode == .text
            if isText, let data, !data.isEmpty {
                if !acknowledged {
                    acknowledged = true
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ackContext = NWConnection.ContentContext(identifier: "ack", metadata: [metadata])
                    connection.send(
                        content: Data(#"{"sessionId":"loopback-session"}"#.utf8),
                        contentContext: ackContext,
                        isComplete: true,
                        completion: .contentProcessed { _ in }
                    )
                } else if String(decoding: data, as: UTF8.self).contains("endStream") {
                    connection.cancel()
                    return
                }
            }
            self.receiveNext(on: connection, acknowledged: acknowledged)
        }
    }
}

/// Rendezvous for the stitching closure: the closure parks in
/// `blockUntilOpened`, the test observes it via `waitUntilBlocked`, swaps the
/// socket, `open`s the gate, and `waitUntilReleased` confirms the closure has
/// resumed before the test inspects session state.
private actor StitchingGate {
    private var blocked = false
    private var opened = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var releasedWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilOpened() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        if !opened {
            await withCheckedContinuation { openWaiters.append($0) }
        }
        released = true
        releasedWaiters.forEach { $0.resume() }
        releasedWaiters.removeAll()
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        opened = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { releasedWaiters.append($0) }
    }
}

@Suite struct MetaRealtimeSessionTests {
    /// The stitching embedding boundary must hand FluidAudio 16 kHz samples:
    /// 24 kHz wire-format speaker audio resampled back down has to reproduce
    /// the original 16 kHz capture signal, not a 1.5x time-stretched copy.
    @Test func embeddingBoundaryResampleRestoresSixteenKilohertzTiming() throws {
        let original: [Int16] = (0..<8_000).map {
            Int16((sin(Double($0) * 2 * .pi * 100 / 16_000) * 12_000).rounded())
        }
        var ingress = try MetaPCMResampler(inputSampleRate: 16_000)
        let wirePCM = ingress.convert(Data.int16LittleEndian(original))
        #expect(wirePCM.count > original.count * 2)

        let embeddingInput = PCMResampler.resampleMono(
            input: MetaPCMResampler.samples(from: wirePCM),
            inputSampleRate: Double(MetaAudioFormat.pcm24KHz.sampleRate)
        )

        let reference = PCMResampler.int16ToFloat(original)
        #expect(abs(embeddingInput.count - reference.count) <= 3)
        var maximumError: Float = 0
        for index in 0..<min(embeddingInput.count, reference.count) {
            maximumError = max(maximumError, abs(embeddingInput[index] - reference[index]))
        }
        #expect(maximumError < 0.02)
    }

    /// Regression for the post-await stale-event guard: a speaker event whose
    /// stitching embedding is still in flight when the socket is swapped (the
    /// 55-minute reconnect path) must be dropped, not applied to the fresh
    /// session's reducer and billing accounting.
    @Test func staleSpeakerEventSuspendedInStitchingIsDroppedAfterSocketSwap() async throws {
        let server = try await LoopbackMetaRealtimeServer.started()
        defer { server.stop() }
        let gate = StitchingGate()
        let stitching = MetaRealtimeSpeakerStitching(profiles: []) { _ in
            await gate.blockUntilOpened()
            return nil
        }
        let session = try MetaRealtimeSession(
            configuration: MetaTranscriptionConfiguration(apiKey: "loopback-test-key"),
            sessionConfig: STTSessionConfig(sampleRate: MetaAudioFormat.pcm24KHz.sampleRate),
            endpoint: server.endpoint,
            speakerStitching: stitching
        )
        try await session.start()
        var results = session.results.makeAsyncIterator()

        // An old-session speaker event carrying ~55 minutes of audio progress.
        try await server.send(
            #"{"type":"speaker","label":"S1","audioProcessedMs":3300000}"#,
            toConnection: 0
        )
        await gate.waitUntilBlocked()

        // Swap the socket while handle(event:) is suspended in the stitching
        // await; connect() resets the reducer, timeline, and billing state
        // exactly as the 55-minute reconnect does.
        try await session.start()
        await gate.open()
        await gate.waitUntilReleased()
        try await Task.sleep(for: .milliseconds(300))

        let staleBilled = await session.billedSeconds()
        #expect(staleBilled == 0)

        // The fresh socket must still deliver events into the shared stream,
        // and billing must reflect only the fresh session's audio progress.
        try await server.send(
            #"{"type":"speechStart","turnId":1,"audioProcessedMs":100}"#,
            toConnection: 1
        )
        try await server.send(
            #"{"type":"speechComplete","turnId":1,"transcript":"Fresh session turn.","audioProcessedMs":2000}"#,
            toConnection: 1
        )
        let fresh = try await results.next()
        #expect(fresh?.text == "Fresh session turn.")
        let billed = await session.billedSeconds()
        #expect(billed == 2)
    }
}
