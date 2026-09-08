import Foundation

/// Makes Meta an optional engine rather than a point of failure. File work
/// retries on the always-available local provider. Live work keeps the local
/// session warm, so an auth, quota, policy, or network failure never drops the
/// audio already captured by the call.
public struct MetaFallbackProvider: STTProvider {
    public let meta: MetaRealtimeProvider
    public let local: any STTProvider

    public var id: STTProviderID { .metaMuse }
    public var supportsStreaming: Bool { true }
    public var providesDiarization: Bool { true }
    public var sendsAudioOffDevice: Bool { true }

    public init(meta: MetaRealtimeProvider, local: any STTProvider) {
        self.meta = meta
        self.local = local
    }

    public func healthCheck() async -> ProviderHealth {
        let metaHealth = await meta.healthCheck()
        guard metaHealth.isUsable else { return metaHealth }
        let localHealth = await local.healthCheck()
        return localHealth.isUsable
            ? .healthy
            : .degraded(reason: "Meta is available, but the local fallback is unavailable")
    }

    public func startSession(config: STTSessionConfig) async throws -> STTSession {
        do {
            let primary = try await meta.startSession(config: config)
            let fallback = try await local.startSession(config: config)
            let session = MetaFallbackSession(primary: primary, fallback: fallback)
            await session.start()
            return session
        } catch {
            // An auth or quota failure happens during the Meta handshake. The
            // caller still receives a normal local session instead of losing a call.
            return try await local.startSession(config: config)
        }
    }

    public func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] {
        do {
            return try await meta.transcribe(fileURL: fileURL, config: config)
        } catch {
            return try await local.transcribe(fileURL: fileURL, config: config)
        }
    }
}

/// Buffers local results until the remote session fails, then emits that
/// complete local history followed by future local results. Keeping the local
/// session warm avoids an unbounded PCM memory buffer and preserves live audio.
public actor MetaFallbackSession: STTSession {
    public nonisolated let results: AsyncThrowingStream<RawSegment, Error>
    private let continuation: AsyncThrowingStream<RawSegment, Error>.Continuation
    private let primary: any STTSession
    private let fallback: any STTSession
    private var primaryTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var bufferedFallback: [RawSegment] = []
    private var emittedPrimary: [RawSegment] = []
    private var usingFallback = false
    private var finished = false

    init(primary: any STTSession, fallback: any STTSession) {
        self.primary = primary
        self.fallback = fallback
        let stream = AsyncThrowingStream<RawSegment, Error>.makeStream()
        self.results = stream.stream
        self.continuation = stream.continuation
    }

    func start() {
        primaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await segment in self.primary.results {
                    await self.receivePrimary(segment)
                }
            } catch {
                await self.activateFallback()
            }
        }
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await segment in self.fallback.results {
                    await self.receiveFallback(segment)
                }
            } catch {
                await self.fallbackFailed(error)
            }
        }
    }

    public func append(pcm: Data) async throws {
        try await fallback.append(pcm: pcm)
        guard !usingFallback else { return }
        do {
            try await primary.append(pcm: pcm)
        } catch {
            activateFallback()
        }
    }

    public func finish() async throws {
        guard !finished else { return }
        finished = true
        if !usingFallback {
            do {
                try await primary.finish()
            } catch {
                activateFallback()
            }
        }
        do {
            try await fallback.finish()
            await primaryTask?.value
            await fallbackTask?.value
            continuation.finish()
        } catch {
            if usingFallback {
                continuation.finish(throwing: error)
                throw error
            }
            // A local error after a successful Meta completion should not
            // invalidate the cloud transcript already delivered to the caller.
            continuation.finish()
        }
    }

    public func isUsingFallback() -> Bool { usingFallback }

    public func billedSeconds() async -> Int {
        guard let primary = primary as? MetaRealtimeSession else { return 0 }
        return await primary.billedSeconds()
    }

    private func receivePrimary(_ segment: RawSegment) {
        guard !usingFallback else { return }
        emittedPrimary.append(segment)
        continuation.yield(segment)
    }

    private func receiveFallback(_ segment: RawSegment) {
        if usingFallback {
            if !duplicatesEmittedPrimary(segment) {
                continuation.yield(segment)
            }
        } else {
            bufferedFallback.append(segment)
        }
    }

    private func activateFallback() {
        guard !usingFallback else { return }
        usingFallback = true
        bufferedFallback
            .filter { !duplicatesEmittedPrimary($0) }
            .forEach { continuation.yield($0) }
        bufferedFallback.removeAll(keepingCapacity: false)
        primaryTask?.cancel()
    }

    private func duplicatesEmittedPrimary(_ candidate: RawSegment) -> Bool {
        emittedPrimary.contains { existing in
            existing.start < candidate.end && candidate.start < existing.end
                && normalized(existing.text) == normalized(candidate.text)
        }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private func fallbackFailed(_ error: Error) {
        guard usingFallback else { return }
        continuation.finish(throwing: error)
    }
}
