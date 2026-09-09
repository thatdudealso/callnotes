@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import os.log

private let speechProviderLog = OSLog(
    subsystem: "com.thatdudealso.callnotes",
    category: "AppleSpeechProvider"
)

/// Local SpeechAnalyzer engine (plan 5.2). Dual-instance validation runs up
/// front; if two concurrent analyzers contend, live work stays on the near
/// channel and the far channel is batched at hang-up.
public struct AppleSpeechProvider: STTProvider {
    public let id: STTProviderID = .appleSpeech
    public let supportsStreaming = true
    public let providesDiarization = false
    public let sendsAudioOffDevice = false

    public var dualInstanceMode: DualInstanceMode

    public init(dualInstanceMode: DualInstanceMode = .concurrentLive) {
        self.dualInstanceMode = dualInstanceMode
    }

    /// Probe two concurrent SpeechAnalyzer instances and remember the result.
    public static func validated() async -> AppleSpeechProvider {
        let result = await DualInstanceProbe.run()
        return AppleSpeechProvider(dualInstanceMode: result.mode)
    }

    public func healthCheck() async -> ProviderHealth {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable(reason: "SpeechTranscriber is not available on this device")
        }
        return .healthy
    }

    public func startSession(config: STTSessionConfig) async throws -> STTSession {
        let session = AppleSpeechSession(config: config, channel: nil)
        try await session.start()
        return session
    }

    public func transcribe(fileURL: URL, config: STTSessionConfig) async throws -> [RawSegment] {
        try await transcribeFile(fileURL: fileURL, config: config) { pcm16, channel, config in
            try await transcribePCM(pcm16, channel: channel, config: config)
        }
    }

    func transcribeFile(
        fileURL: URL,
        config: STTSessionConfig,
        transcribePCM: @escaping @Sendable (Data, SegmentChannel, STTSessionConfig) async throws -> [RawSegment]
    ) async throws -> [RawSegment] {
        let loaded = try FileAudioLoader.load(fileURL, targetSampleRate: config.sampleRate)
        if !loaded.isStereo {
            return try await transcribePCM(loaded.near, .mixed, config)
        }

        switch dualInstanceMode {
        case .concurrentLive:
            async let near = transcribePCM(loaded.near, .near, config)
            async let far = transcribePCM(loaded.far, .far, config)
            let combined = try await near + far
            return combined.sorted { $0.start < $1.start }
        case .nearLiveFarBatch:
            let near = try await transcribePCM(loaded.near, .near, config)
            let far = try await transcribePCM(loaded.far, .far, config)
            return (near + far).sorted { $0.start < $1.start }
        }
    }

    public func transcribePCM(
        _ pcm16: Data,
        channel: SegmentChannel,
        config: STTSessionConfig
    ) async throws -> [RawSegment] {
        guard !pcm16.isEmpty else { return [] }
        let session = AppleSpeechSession(config: config, channel: channel)
        try await session.start()
        try await session.append(pcm: pcm16)
        try await session.finish()
        var segments: [RawSegment] = []
        for try await segment in session.results {
            if !segment.isVolatile {
                segments.append(segment)
            }
        }
        return segments
    }
}

public final class AppleSpeechSession: STTSession, @unchecked Sendable {
    public let results: AsyncThrowingStream<RawSegment, Error>
    private let continuation: AsyncThrowingStream<RawSegment, Error>.Continuation
    private let config: STTSessionConfig
    private let channel: SegmentChannel?

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Error>?
    private let sourceFormat: AVAudioFormat?

    public init(config: STTSessionConfig, channel: SegmentChannel?) {
        self.config = config
        self.channel = channel
        self.sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(config.sampleRate),
            channels: 1,
            interleaved: true
        )
        let stream = AsyncThrowingStream<RawSegment, Error>.makeStream()
        self.results = stream.stream
        self.continuation = stream.continuation
    }

    public func start() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerServiceError.transcriberUnavailable
        }
        let locale = try await SpeechLocaleResolver.resolve(
            preference: config.locale.identifier(.bcp47)
        )
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        try await SpeechAnalyzerService.ensureAssets(for: transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !config.customVocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = config.customVocabulary
            do {
                try await analyzer.setContext(context)
            } catch {
                os_log(
                    .error,
                    log: speechProviderLog,
                    "setContext failed: %{public}@",
                    error.localizedDescription
                )
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            throw SpeechAnalyzerServiceError.noCompatibleAudioFormat
        }
        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let channel = self.channel
        let continuation = self.continuation
        resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                let words = words(from: result.text)
                continuation.yield(
                    RawSegment(
                        start: start.isFinite ? start : 0,
                        end: end.isFinite ? end : start,
                        text: text,
                        words: words.isEmpty ? nil : words,
                        speakerTag: channel == .near ? TurnAttributor.ownerClusterKey : nil,
                        channel: channel,
                        isVolatile: !result.isFinal
                    )
                )
            }
        }
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            builder.finish()
            resultsTask?.cancel()
            resultsTask = nil
            continuation.finish(throwing: error)
            throw error
        }
        self.analyzer = analyzer
        self.inputBuilder = builder
        self.analyzerFormat = format
    }

    public func append(pcm: Data) async throws {
        guard let inputBuilder, let analyzerFormat, let sourceFormat else {
            throw SpeechAnalyzerServiceError.sessionNotStarted
        }
        let frameCount = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
            let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount),
            let channelData = sourceBuffer.int16ChannelData
        else {
            return
        }
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channelData[0], base, Int(frameCount) * MemoryLayout<Int16>.size)
        }
        sourceBuffer.frameLength = frameCount

        if converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            return
        }
        let inputState = AppleSpeechConversionInput(sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { [inputState] _, outStatus in
            if inputState.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.consumed = true
            outStatus.pointee = .haveData
            return inputState.source
        }
        if status == .error {
            os_log(
                .error,
                log: speechProviderLog,
                "audio conversion failed: %{public}@",
                conversionError?.localizedDescription ?? "unknown"
            )
            return
        }
        if converted.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
    }

    public func finish() async throws {
        inputBuilder?.finish()
        inputBuilder = nil
        do {
            if let analyzer {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            try await resultsTask?.value
            continuation.finish()
            analyzer = nil
            resultsTask = nil
        } catch {
            resultsTask?.cancel()
            resultsTask = nil
            analyzer = nil
            continuation.finish(throwing: error)
            throw error
        }
    }
}

/// AVAudioConverter invokes this source closure synchronously for one buffer.
/// The wrapper confines the checked-externally Sendable boundary to that API.
private final class AppleSpeechConversionInput: @unchecked Sendable {
    let source: AVAudioPCMBuffer
    var consumed = false

    init(_ source: AVAudioPCMBuffer) {
        self.source = source
    }
}

private func words(from text: AttributedString) -> [Word] {
    var collected: [Word] = []
    for run in text.runs {
        let piece = String(text[run.range].characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { continue }
        if let range = run.audioTimeRange {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            collected.append(
                Word(
                    text: piece,
                    start: start.isFinite ? start : 0,
                    end: end.isFinite ? end : start
                )
            )
        }
    }
    return collected
}
