//
//  SpeechAnalyzerService.swift
//  CallNotesCore
//
//  Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone),
//  MIT License:
//    Copyright (c) 2026 Kuber Mehta (Megaphone)
//    Copyright (c) 2026 Zach Latta (FreeFlow)
//  See THIRD_PARTY.md for the full license text and the per-component
//  reuse decision. Adapted for CallNotes: renamed the log subsystem and
//  queue labels, made the streaming input sample rate configurable, and
//  removed Megaphone-specific legacy locale aliases.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech
import os.log

private let speechLog = OSLog(subsystem: "com.thatdudealso.callnotes", category: "SpeechAnalyzer")

/// AVAudioConverter invokes this source closure synchronously for one buffer.
/// The wrapper confines the checked-externally Sendable boundary to that API.
private final class SpeechServiceConversionInput: @unchecked Sendable {
    let source: AVAudioPCMBuffer
    var consumed = false

    init(_ source: AVAudioPCMBuffer) {
        self.source = source
    }
}

// MARK: - Errors

public enum SpeechAnalyzerServiceError: Error, LocalizedError {
    case transcriberUnavailable
    case unsupportedLocale(String)
    case noCompatibleAudioFormat
    case audioBufferCreationFailed
    case noAudioSamples
    case resultStreamTimedOut
    case sessionNotStarted

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            return "On-device transcription is not available on this device. SpeechAnalyzer requires macOS 26 / iOS 26 on supported hardware."
        case .unsupportedLocale(let identifier):
            return "The language \"\(identifier)\" is not supported by Apple's on-device speech model."
        case .noCompatibleAudioFormat:
            return "No compatible audio format is available for on-device transcription."
        case .audioBufferCreationFailed:
            return "Could not prepare audio buffers for on-device transcription."
        case .noAudioSamples:
            return "No audio samples reached the on-device transcriber."
        case .resultStreamTimedOut:
            return "On-device transcription did not finish returning results."
        case .sessionNotStarted:
            return "The on-device transcription session was never started."
        }
    }
}

// MARK: - Locale resolution

/// Maps the stored language preference onto a locale supported by
/// `SpeechTranscriber`. Handles "auto", bare ISO codes like "en"/"hi",
/// and full BCP-47 identifiers.
public enum SpeechLocaleResolver {
    /// Preference values that mean "no explicit language".
    private static let autoValues: Set<String> = ["", "auto"]

    public static func resolve(preference: String) async throws -> Locale {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else {
            throw SpeechAnalyzerServiceError.transcriberUnavailable
        }

        if autoValues.contains(trimmed.lowercased()) {
            return bestMatch(for: Locale.current, in: supported)
                ?? preferredEnglish(in: supported)
                ?? supported[0]
        }

        let requested = Locale(identifier: trimmed)
        if let match = bestMatch(for: requested, in: supported) {
            return match
        }
        throw SpeechAnalyzerServiceError.unsupportedLocale(trimmed)
    }

    /// Exact BCP-47 match first, then any supported locale with the same
    /// language code (e.g. "en" or "en-NZ" settle on "en-US").
    public static func bestMatch(for locale: Locale, in supported: [Locale]) -> Locale? {
        let target = locale.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == target }) {
            return exact
        }
        guard let language = locale.language.languageCode?.identifier, !language.isEmpty else {
            return nil
        }
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    private static func preferredEnglish(in supported: [Locale]) -> Locale? {
        supported.first { $0.identifier(.bcp47) == "en-US" }
            ?? supported.first { $0.language.languageCode?.identifier == "en" }
    }

    /// Options for the settings picker: "auto" plus every locale the
    /// on-device model supports, sorted by display name.
    public static func pickerOptions() async -> [(code: String, name: String)] {
        let supported = await SpeechTranscriber.supportedLocales
        let locales = supported
            .map { locale -> (code: String, name: String) in
                let code = locale.identifier(.bcp47)
                let name = Locale.current.localizedString(forIdentifier: code) ?? code
                return (code, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [("auto", "Auto (System Language)")] + locales
    }
}

// MARK: - Core service

public enum SpeechAnalyzerService {
    /// Splits free-form vocabulary text into individual terms and wraps them
    /// in an `AnalysisContext` so the on-device model is biased toward the
    /// user's names and jargon (fed from the Dictionary feature).
    public static func vocabularyContext(from rawVocabulary: String) -> AnalysisContext? {
        let terms = rawVocabulary
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        return context
    }

    public static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Downloads and reserves the locale's model assets when missing. Safe to
    /// call repeatedly; returns immediately when everything is installed.
    public static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == target }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                os_log(.info, log: speechLog, "downloading speech model assets for %{public}@", target)
                try await request.downloadAndInstall()
                os_log(.info, log: speechLog, "speech model assets installed for %{public}@", target)
            }
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == target }) {
            // Only one locale is ever needed at a time; free the slots held
            // for previously used languages so the app's small reservation
            // quota can't fill up after a few language switches.
            for staleLocale in reserved {
                await AssetInventory.release(reservedLocale: staleLocale)
            }
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                // Reservation can fail when the system quota is exhausted;
                // assets that are already installed keep working, so log and
                // continue.
                os_log(.error, log: speechLog, "could not reserve locale %{public}@: %{public}@",
                       target, error.localizedDescription)
            }
        }
    }

    /// Transcribes a recorded audio file entirely on-device.
    public static func transcribe(
        fileURL: URL,
        localePreference: String,
        vocabulary: String
    ) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerServiceError.transcriberUnavailable
        }
        let locale = try await SpeechLocaleResolver.resolve(preference: localePreference)
        let transcriber = makeTranscriber(locale: locale)
        try await ensureAssets(for: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let context = vocabularyContext(from: vocabulary) {
            do {
                try await analyzer.setContext(context)
            } catch {
                os_log(.error, log: speechLog, "setContext failed: %{public}@", error.localizedDescription)
            }
        }

        let resultsTask = Task<String, Error> {
            var transcript = AttributedString("")
            for try await result in transcriber.results {
                transcript += result.text
            }
            return String(transcript.characters)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let audioDuration = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)

        do {
            guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw SpeechAnalyzerServiceError.noAudioSamples
            }
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        // On-device analysis runs far faster than realtime, so results should
        // land quickly; the timeout only guards against a wedged stream.
        let timeout = max(30.0, audioDuration + 30.0)
        do {
            let transcript = try await awaiting(resultsTask, timeout: timeout)
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Races `task` against a timeout so a stalled result stream can't hang
    /// the transcription pipeline forever. The wait is wrapped in a
    /// cancellation handler because cancelling a group child does not cancel
    /// the unstructured task it awaits — without it, a wedged result stream
    /// would keep the group (and caller) suspended even after the timeout.
    public static func awaiting(_ task: Task<String, Error>, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SpeechAnalyzerServiceError.resultStreamTimedOut
            }
            guard let winner = try await group.next() else {
                throw SpeechAnalyzerServiceError.resultStreamTimedOut
            }
            group.cancelAll()
            return winner
        }
    }
}

// MARK: - Streaming session

/// Feeds live PCM audio into a `SpeechAnalyzer` while capture is still in
/// progress, so the transcript is essentially finished the moment the call
/// ends.
///
/// Audio arrives as raw PCM16 samples (mono, at `sourceSampleRate`), is
/// converted to the analyzer's preferred format, and streamed as
/// `AnalyzerInput`. Setup (locale resolution, model check, analyzer start)
/// happens asynchronously; samples that arrive earlier are buffered and
/// flushed once the analyzer is running.
///
/// Call `appendPCM16(_:)` from any thread while capturing, then
/// `commitAndAwaitFinal()` from an async context when capture stops. If the
/// session failed to start, `commitAndAwaitFinal()` throws and the caller
/// falls back to file-based transcription.
public final class SpeechAnalyzerStreamingSession: @unchecked Sendable {
    private let localePreference: String
    private let vocabulary: String

    /// Serializes all mutable state below and orders sample delivery.
    private let queue = DispatchQueue(label: "com.thatdudealso.callnotes.speechanalyzer-input")
    private var pendingSamples: [Data] = []
    private var finished = false
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<String, Error>?
    private var setupTask: Task<Void, Error>?

    /// Format of the samples handed to `appendPCM16`: mono Int16 at the
    /// capture graph's local sample rate.
    private let sourceFormat: AVAudioFormat?

    public init(
        localePreference: String,
        vocabulary: String,
        sourceSampleRate: Double = Double(AudioConstants.localSampleRate)
    ) {
        self.localePreference = localePreference
        self.vocabulary = vocabulary
        self.sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: true
        )
    }

    // MARK: Lifecycle

    /// Kicks off asynchronous setup. Failures are stored in `setupTask` and
    /// surface when `commitAndAwaitFinal()` awaits it.
    public func start() {
        setupTask = Task { [self] in
            guard SpeechTranscriber.isAvailable else {
                throw SpeechAnalyzerServiceError.transcriberUnavailable
            }
            let locale = try await SpeechLocaleResolver.resolve(preference: localePreference)
            let transcriber = SpeechAnalyzerService.makeTranscriber(locale: locale)
            try await SpeechAnalyzerService.ensureAssets(for: transcriber, locale: locale)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if let context = SpeechAnalyzerService.vocabularyContext(from: vocabulary) {
                do {
                    try await analyzer.setContext(context)
                } catch {
                    os_log(.error, log: speechLog, "setContext failed: %{public}@", error.localizedDescription)
                }
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw SpeechAnalyzerServiceError.noCompatibleAudioFormat
            }

            let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            let collector = Task<String, Error> {
                var transcript = AttributedString("")
                for try await result in transcriber.results {
                    transcript += result.text
                }
                return String(transcript.characters)
            }
            try await analyzer.start(inputSequence: inputSequence)

            queue.sync {
                self.resultsTask = collector
                if self.finished {
                    // Cancelled while setting up: shut the analyzer back down.
                    builder.finish()
                    collector.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                    return
                }
                self.analyzer = analyzer
                self.inputBuilder = builder
                self.analyzerFormat = format
                let backlog = self.pendingSamples
                self.pendingSamples.removeAll()
                for data in backlog {
                    self.convertAndYieldLocked(data)
                }
            }
            os_log(.info, log: speechLog, "streaming session started (locale: %{public}@)",
                   locale.identifier(.bcp47))
        }
    }

    /// Append raw PCM16 samples. Safe to call from any thread or queue.
    public func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !finished else { return }
            if inputBuilder != nil {
                convertAndYieldLocked(data)
            } else {
                pendingSamples.append(data)
            }
        }
    }

    /// Stop accepting audio, finalize the analysis, and return the full
    /// transcript.
    public func commitAndAwaitFinal() async throws -> String {
        guard let setupTask else {
            throw SpeechAnalyzerServiceError.sessionNotStarted
        }
        try await setupTask.value

        var analyzer: SpeechAnalyzer?
        var resultsTask: Task<String, Error>?
        queue.sync {
            finished = true
            inputBuilder?.finish()
            inputBuilder = nil
            analyzer = self.analyzer
            resultsTask = self.resultsTask
        }
        guard let analyzer, let resultsTask else {
            throw SpeechAnalyzerServiceError.sessionNotStarted
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let transcript = try await SpeechAnalyzerService.awaiting(resultsTask, timeout: 60)
        queue.sync {
            // Analysis is complete; a later cancel() must be a pure no-op.
            self.analyzer = nil
            self.resultsTask = nil
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandon the session without producing a transcript.
    public func cancel() {
        setupTask?.cancel()
        queue.async { [self] in
            finished = true
            pendingSamples.removeAll()
            inputBuilder?.finish()
            inputBuilder = nil
            resultsTask?.cancel()
            if let analyzer {
                Task { await analyzer.cancelAndFinishNow() }
            }
            analyzer = nil
        }
    }

    // MARK: Audio conversion

    /// Must be called on `queue`. Converts one chunk of raw PCM16 samples to
    /// the analyzer's format and yields it to the input stream.
    private func convertAndYieldLocked(_ data: Data) {
        guard let inputBuilder, let analyzerFormat, let sourceFormat else { return }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount),
              let channel = sourceBuffer.int16ChannelData
        else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            memcpy(channel[0], base, Int(frameCount) * MemoryLayout<Int16>.size)
        }
        sourceBuffer.frameLength = frameCount

        if converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            // Avoid timestamp drift from converter priming (Apple sample code).
            converter?.primeMethod = .none
        }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: max(capacity, 1)) else {
            return
        }

        let inputState = SpeechServiceConversionInput(sourceBuffer)
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
            os_log(.error, log: speechLog, "audio conversion failed: %{public}@",
                   conversionError?.localizedDescription ?? "unknown")
            return
        }
        if converted.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
    }
}

// MARK: - Model status for the UI

/// Observable download/installation state of the on-device speech model for
/// the currently selected language, displayed in Settings and Setup.
@MainActor
public final class SpeechModelManager: ObservableObject {
    public enum Status: Equatable {
        case unknown
        case unavailable
        case unsupportedLanguage(String)
        case needsDownload(String)
        case downloading(String)
        case installed(String)
        case failed(String)

        public var description: String {
            switch self {
            case .unknown:
                return "Checking speech model..."
            case .unavailable:
                return "On-device transcription is unavailable on this device."
            case .unsupportedLanguage(let name):
                return "\(name) is not supported by the on-device speech model."
            case .needsDownload(let name):
                return "The \(name) speech model needs to be downloaded."
            case .downloading(let name):
                return "Downloading the \(name) speech model..."
            case .installed(let name):
                return "The \(name) speech model is installed."
            case .failed(let message):
                return "Speech model error: \(message)"
            }
        }
    }

    @Published public private(set) var status: Status = .unknown

    private var refreshTask: Task<Void, Never>?

    /// Nonisolated so non-main-actor owners can create one; all state access
    /// still happens on the main actor.
    public nonisolated init() {}

    public func refresh(localePreference: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard SpeechTranscriber.isAvailable else {
                self?.status = .unavailable
                return
            }
            let locale: Locale
            do {
                locale = try await SpeechLocaleResolver.resolve(preference: localePreference)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .unsupportedLanguage(Self.displayName(for: localePreference))
                return
            }
            let name = Self.displayName(for: locale.identifier(.bcp47))
            let installed = await SpeechTranscriber.installedLocales
            guard !Task.isCancelled else { return }
            if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                self?.status = .installed(name)
            } else {
                self?.status = .needsDownload(name)
            }
        }
    }

    /// Download the model for the given language preference, updating
    /// `status` as it progresses.
    public func download(localePreference: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard SpeechTranscriber.isAvailable else {
                self?.status = .unavailable
                return
            }
            let locale: Locale
            do {
                locale = try await SpeechLocaleResolver.resolve(preference: localePreference)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .unsupportedLanguage(Self.displayName(for: localePreference))
                return
            }
            let name = Self.displayName(for: locale.identifier(.bcp47))
            guard !Task.isCancelled else { return }
            self?.status = .downloading(name)
            do {
                let transcriber = SpeechAnalyzerService.makeTranscriber(locale: locale)
                try await SpeechAnalyzerService.ensureAssets(for: transcriber, locale: locale)
                guard !Task.isCancelled else { return }
                self?.status = .installed(name)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    private static func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
