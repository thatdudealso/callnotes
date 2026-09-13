import Foundation

/// When the paired Mac cannot be reached, the iPhone transcribes locally so
/// the user still has a speaker-labeled transcript (plan Phase 7).
public enum OnDeviceFallback: Sendable {
    public static let defaultsKey = "on_device_fallback"

    public static func shouldTranscribe(
        isEnabled: Bool,
        isMacReachable: Bool,
        alreadyHasTranscript: Bool
    ) -> Bool {
        isEnabled && !isMacReachable && !alreadyHasTranscript
    }

    /// Transport failures mean the Mac never saw the audio. HTTP 4xx from a
    /// paired Mac is a refusal, not unreachability, and must not start a
    /// fallback that would duplicate a Mac-side transcript later.
    public static func isMacUnreachable(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        let lowered = message.lowercased()
        if lowered.contains("unpaired") { return false }
        if lowered.contains("http 4") { return false }
        if lowered.contains("could not") { return true }
        if lowered.contains("timed out") { return true }
        if lowered.contains("offline") { return true }
        if lowered.contains("network") { return true }
        if lowered.contains("not reachable") { return true }
        if lowered.contains("failed to connect") { return true }
        if lowered.contains("connection") { return true }
        return false
    }
}

public struct OnDeviceFallbackTranscript: Codable, Sendable, Equatable {
    public var callID: UUID
    public var startedAt: Date
    public var segments: [RawSegment]
    public var provider: STTProviderID

    public init(callID: UUID, startedAt: Date, segments: [RawSegment], provider: STTProviderID) {
        self.callID = callID
        self.startedAt = startedAt
        self.segments = segments
        self.provider = provider
    }
}

public enum OnDeviceFallbackStore: Sendable {
    public static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    public static func write(_ transcript: OnDeviceFallbackTranscript, nextTo audioURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FallbackSidecar(from: transcript))
        try data.write(to: sidecarURL(for: audioURL), options: .atomic)
    }

    public static func load(nextTo audioURL: URL) throws -> OnDeviceFallbackTranscript? {
        let url = sidecarURL(for: audioURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(FallbackSidecar.self, from: data)
        return sidecar.transcript
    }
}

private struct FallbackSidecar: Codable, Sendable {
    struct Line: Codable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var channel: SegmentChannel?
    }

    var callID: UUID
    var startedAt: Date
    var provider: STTProviderID
    var segments: [Line]

    init(from transcript: OnDeviceFallbackTranscript) {
        callID = transcript.callID
        startedAt = transcript.startedAt
        provider = transcript.provider
        segments = transcript.segments.map {
            Line(start: $0.start, end: $0.end, text: $0.text, channel: $0.channel)
        }
    }

    var transcript: OnDeviceFallbackTranscript {
        OnDeviceFallbackTranscript(
            callID: callID,
            startedAt: startedAt,
            segments: segments.map {
                RawSegment(start: $0.start, end: $0.end, text: $0.text, channel: $0.channel)
            },
            provider: provider
        )
    }
}

public struct OnDeviceFallbackTranscriber: Sendable {
    public var speech: any PCMTranscriber

    public init(speech: any PCMTranscriber) {
        self.speech = speech
    }

    public func transcribe(fileURL: URL, callID: UUID, startedAt: Date) async throws -> OnDeviceFallbackTranscript {
        let loaded = try FileAudioLoader.load(fileURL, targetSampleRate: AudioConstants.localSampleRate)
        let config = STTSessionConfig(sampleRate: loaded.sampleRate)
        let pcm = loaded.mixed.isEmpty ? loaded.near : loaded.mixed
        let channel: SegmentChannel = loaded.isStereo ? .near : .mixed
        var segments = try await speech.transcribePCM(pcm, channel: channel, config: config)
        if loaded.isStereo, !loaded.far.isEmpty {
            let far = try await speech.transcribePCM(loaded.far, channel: .far, config: config)
            segments.append(contentsOf: far)
            segments.sort { $0.start < $1.start }
        }
        return OnDeviceFallbackTranscript(
            callID: callID,
            startedAt: startedAt,
            segments: segments,
            provider: speech.id
        )
    }
}
