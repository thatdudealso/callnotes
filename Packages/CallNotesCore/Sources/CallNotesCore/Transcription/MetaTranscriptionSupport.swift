import Foundation

/// Constants required by the pinned Meta Muse Voice Transcribe model.
public enum MetaAudioFormat: Sendable {
    case pcm24KHz

    public var sampleRate: Int { 24_000 }
    public var bytesPerSample: Int { 2 }
    public var byteRate: Int { sampleRate * bytesPerSample }
}

/// Errors surfaced by the Meta provider. These stay client-safe because the
/// remote API intentionally returns a single safe message for HTTP failures.
public enum MetaTranscriptionError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidWAV(String)
    case unauthorized(String)
    case quotaExceeded(String)
    case streamingPolicy(String)
    case backend(String)
    case transport(String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "A Meta Model API key is required."
        case let .invalidWAV(message), let .unauthorized(message), let .quotaExceeded(message),
            let .streamingPolicy(message), let .backend(message), let .transport(message),
            let .unexpectedResponse(message): message
        }
    }

    static func fromHTTP(status: Int, message: String) -> MetaTranscriptionError {
        switch status {
        case 401, 403: .unauthorized(message)
        case 429: .quotaExceeded(message)
        case 400, 413: .invalidWAV(message)
        case 500...599: .backend(message)
        default: .unexpectedResponse(message)
        }
    }
}

/// Settings fixed at the Meta handshake or file request boundary.
public struct MetaTranscriptionConfiguration: Sendable, Equatable {
    public static let modelID = "muse-voice-transcribe-1.0"

    public var apiKey: String
    public var languageBias: [String]
    public var keywords: [String]
    /// Only realtime accepts this field. It defaults to true because CallNotes
    /// never silently opts a customer into content retention.
    public var zeroDataRetention: Bool

    public init(
        apiKey: String,
        languageBias: [String] = ["English"],
        keywords: [String] = [],
        zeroDataRetention: Bool = true
    ) {
        self.apiKey = apiKey
        self.languageBias = languageBias
        self.keywords = keywords
        self.zeroDataRetention = zeroDataRetention
    }
}

/// Pure pacing math, kept outside the WebSocket actor so it can be tested
/// without sleeping or opening a network connection.
public enum MetaRealtimePacing {
    public static let maximumBacklogNanoseconds: Int64 = 5_000_000_000

    public static func requiredSleepNanoseconds(
        sentAudioBytes: Int,
        elapsedNanoseconds: Int64,
        format: MetaAudioFormat = .pcm24KHz
    ) -> Int64 {
        let target = Int64(sentAudioBytes) * 1_000_000_000 / Int64(format.byteRate)
        return max(0, target - elapsedNanoseconds)
    }

    public static func isWithinBacklogLimit(
        sentAudioBytes: Int,
        elapsedNanoseconds: Int64,
        format: MetaAudioFormat = .pcm24KHz
    ) -> Bool {
        requiredSleepNanoseconds(
            sentAudioBytes: sentAudioBytes,
            elapsedNanoseconds: elapsedNanoseconds,
            format: format
        ) <= maximumBacklogNanoseconds
    }
}

/// Pricing is $0.18/hour, with seconds rounded down by the service.
public enum MetaCostMeter {
    public static let dollarsPerHour = 0.18

    public static func billedSeconds(audioProcessedMilliseconds: Int) -> Int {
        max(0, audioProcessedMilliseconds / 1_000)
    }

    public static func costDollars(billedSeconds: Int) -> Double {
        Double(max(0, billedSeconds)) * dollarsPerHour / 3_600
    }
}

/// One PCM-frame range submitted to the multipart endpoint.
public struct MetaFileChunk: Sendable, Equatable {
    public let startFrame: Int
    public let frameCount: Int

    public init(startFrame: Int, frameCount: Int) {
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

/// Plans uploads below Meta's 10-minute hard cap and carries a five-second
/// overlap so endpointing does not drop speech spanning a chunk boundary.
public enum MetaFileChunker {
    public static let chunkDurationSeconds = 9.5 * 60
    public static let overlapDurationSeconds = 5.0

    public static func plan(totalFrames: Int, sampleRate: Int) -> [MetaFileChunk] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let chunkFrames = Int(chunkDurationSeconds * Double(sampleRate))
        let overlapFrames = Int(overlapDurationSeconds * Double(sampleRate))
        var result: [MetaFileChunk] = []
        var start = 0
        while start < totalFrames {
            let count = min(chunkFrames, totalFrames - start)
            result.append(MetaFileChunk(startFrame: start, frameCount: count))
            guard start + count < totalFrames else { break }
            start += max(1, count - overlapFrames)
        }
        return result
    }
}

/// Removes only text duplicated by the known upload overlap. This deliberately
/// requires both temporal overlap and normalized-text equality so repeated
/// conversational phrases outside the overlap remain intact.
public enum MetaTranscriptOverlapDeduper {
    public static func merge(
        previous: [RawSegment],
        incoming: [RawSegment],
        incomingOffset: TimeInterval
    ) -> [RawSegment] {
        var merged = previous
        for var segment in incoming {
            segment.start += incomingOffset
            segment.end += incomingOffset
            let duplicate = merged.contains { existing in
                overlaps(existing, segment) && normalized(existing.text) == normalized(segment.text)
            }
            if !duplicate { merged.append(segment) }
        }
        return merged.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    private static func overlaps(_ lhs: RawSegment, _ rhs: RawSegment) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// A locally generated FluidAudio embedding for a provider-local label.
/// Meta labels alone are intentionally not used for cross-session identity.
public struct MetaSpeakerEmbedding: Sendable, Equatable {
    public var sessionID: String
    public var label: String
    public var embedding: [Float]

    public init(sessionID: String, label: String, embedding: [Float]) {
        self.sessionID = sessionID
        self.label = label
        self.embedding = embedding
    }
}

/// Maps each Meta session label to an existing local profile using the same
/// embedding matcher used by the local engine. A reconnect may rename Alex
/// from `A` to `B`, but both map to Alex's profile ID.
public struct MetaSpeakerSessionStitcher: Sendable {
    public var profiles: [SpeakerProfile]

    public init(profiles: [SpeakerProfile]) {
        self.profiles = profiles
    }

    public func stitch(_ embeddings: [MetaSpeakerEmbedding]) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: embeddings.compactMap { item in
            switch SpeakerMatcher.match(embedding: item.embedding, against: profiles) {
            case let .autoLabel(profileID, _), let .suggest(profileID, _):
                ("\(item.sessionID):\(item.label)", profileID)
            case .unknown:
                nil
            }
        })
    }
}

/// User-interface policy for the one-time cloud disclosure.
public struct MetaPrivacyGate: Sendable {
    public init() {}

    public func requiresDisclosure(for provider: STTProviderID, hasAcknowledged: Bool) -> Bool {
        provider == .metaMuse && !hasAcknowledged
    }
}
