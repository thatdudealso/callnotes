import Foundation

/// The transcription engines CallNotes knows about.
public enum STTProviderID: String, Codable, Sendable, CaseIterable {
    case appleSpeech = "apple_speech"
    case fluidParakeet = "fluid_parakeet"
    case metaMuse = "meta_muse"
}

/// Configuration for one transcription session.
public struct STTSessionConfig: Sendable {
    public var locale: Locale
    public var sampleRate: Int
    public var customVocabulary: [String]

    public init(
        locale: Locale = Locale(identifier: "en_US"),
        sampleRate: Int = 16_000,
        customVocabulary: [String] = []
    ) {
        self.locale = locale
        self.sampleRate = sampleRate
        self.customVocabulary = customVocabulary
    }
}

/// A provider-native transcript segment before diarization and identity.
public struct RawSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [Word]?
    /// Provider-native speaker tag, if the provider diarizes (Meta does).
    public var speakerTag: String?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [Word]? = nil,
        speakerTag: String? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.speakerTag = speakerTag
    }
}

/// A live transcription session: feed PCM chunks, receive partial and final segments.
public protocol STTSession: Sendable {
    var results: AsyncThrowingStream<RawSegment, Error> { get }
    func append(pcm: Data) async throws
    func finish() async throws
}

/// Every transcription engine implements this; diarization and speaker identity
/// run after ASR in a provider-independent step, so the engine switch is data.
public protocol STTProvider: Sendable {
    var id: STTProviderID { get }
    var supportsStreaming: Bool { get }
    var providesDiarization: Bool { get }
    var sendsAudioOffDevice: Bool { get }

    /// Live: feed PCM chunks, receive partial + final segments with timestamps.
    func startSession(config: STTSessionConfig) async throws -> STTSession
    /// Offline: whole file -> segments. Used for iPhone imports and re-processing.
    func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment]
    /// Cheap readiness probe used by the health system.
    func healthCheck() async -> ProviderHealth
}

/// Resolves which engine handles a call:
/// (per-call override) -> (configured default) -> Local.
public enum EngineSelection {
    public static let builtInDefault: STTProviderID = .appleSpeech

    public static func resolve(
        override perCallOverride: STTProviderID?,
        configuredDefault: STTProviderID?
    ) -> STTProviderID {
        perCallOverride ?? configuredDefault ?? builtInDefault
    }
}
