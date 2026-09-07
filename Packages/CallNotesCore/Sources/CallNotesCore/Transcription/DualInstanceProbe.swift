import AVFoundation
import Foundation
import Speech
import os.log

private let probeLog = OSLog(subsystem: "com.thatdudealso.callnotes", category: "DualInstanceProbe")

/// How live SpeechAnalyzer instances are scheduled (plan 5.2).
///
/// Two concurrent instances (near + far) are the preferred path. If they
/// contend for the ANE, live transcription stays on the near channel and the
/// far channel is batched at hang-up - the same batch we already run for
/// diarization.
public enum DualInstanceMode: String, Sendable, Codable, Equatable {
    case concurrentLive = "concurrent_live"
    case nearLiveFarBatch = "near_live_far_batch"
}

public struct DualInstanceProbeResult: Sendable, Equatable {
    public var mode: DualInstanceMode
    public var nearStarted: Bool
    public var farStarted: Bool
    public var reason: String?

    public init(
        mode: DualInstanceMode,
        nearStarted: Bool,
        farStarted: Bool,
        reason: String? = nil
    ) {
        self.mode = mode
        self.nearStarted = nearStarted
        self.farStarted = farStarted
        self.reason = reason
    }
}

/// Validates two concurrent `SpeechAnalyzer` instances up front.
public enum DualInstanceProbe {
    public static func resolve(nearStarted: Bool, farStarted: Bool) -> DualInstanceMode {
        (nearStarted && farStarted) ? .concurrentLive : .nearLiveFarBatch
    }

    /// Starts two short-lived SpeechAnalyzer sessions. Either both come up
    /// (concurrent live) or we record the fallback. Safe to call at launch;
    /// failures never throw.
    public static func run(timeout: TimeInterval = 8) async -> DualInstanceProbeResult {
        guard SpeechTranscriber.isAvailable else {
            return DualInstanceProbeResult(
                mode: .nearLiveFarBatch,
                nearStarted: false,
                farStarted: false,
                reason: "SpeechTranscriber unavailable"
            )
        }

        // Hold both analyzers alive at once so ANE contention actually shows up.
        // Sequential start-and-stop would never observe the dual-instance path.
        let attempts = await withTaskGroup(of: ProbeAttempt.self) { group in
            group.addTask { await startProbeAnalyzer(timeout: timeout) }
            group.addTask { await startProbeAnalyzer(timeout: timeout) }
            var collected: [ProbeAttempt] = []
            for await attempt in group {
                collected.append(attempt)
                if collected.count == 2 { break }
            }
            group.cancelAll()
            return collected
        }
        let near = attempts.first ?? ProbeAttempt(
            started: false,
            error: "probe timed out",
            analyzer: nil,
            inputContinuation: nil
        )
        let far = attempts.count > 1
            ? attempts[1]
            : ProbeAttempt(
                started: false,
                error: "probe timed out",
                analyzer: nil,
                inputContinuation: nil
            )
        near.inputContinuation?.finish()
        far.inputContinuation?.finish()
        await near.analyzer?.cancelAndFinishNow()
        await far.analyzer?.cancelAndFinishNow()

        let mode = resolve(nearStarted: near.started, farStarted: far.started)
        if mode == .nearLiveFarBatch {
            os_log(
                .error,
                log: probeLog,
                "dual SpeechAnalyzer probe fell back (near=%{public}@ far=%{public}@): %{public}@",
                near.started ? "ok" : "fail",
                far.started ? "ok" : "fail",
                far.error ?? near.error ?? "unknown"
            )
        } else {
            os_log(.info, log: probeLog, "dual SpeechAnalyzer probe: concurrent live is available")
        }
        return DualInstanceProbeResult(
            mode: mode,
            nearStarted: near.started,
            farStarted: far.started,
            reason: mode == .nearLiveFarBatch ? (far.error ?? near.error) : nil
        )
    }

    private struct ProbeAttempt: @unchecked Sendable {
        var started: Bool
        var error: String?
        var analyzer: SpeechAnalyzer?
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    }

    private actor ProbeAttemptRacer {
        private var result: ProbeAttempt?
        private var continuation: CheckedContinuation<ProbeAttempt, Never>?

        func finish(_ attempt: ProbeAttempt) {
            guard result == nil else {
                if let analyzer = attempt.analyzer {
                    Task { await analyzer.cancelAndFinishNow() }
                }
                return
            }
            result = attempt
            continuation?.resume(returning: attempt)
            continuation = nil
        }

        func value() async -> ProbeAttempt {
            if let result {
                return result
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    private static func startProbeAnalyzer(timeout: TimeInterval) async -> ProbeAttempt {
        let racer = ProbeAttemptRacer()
        Task {
            let attempt: ProbeAttempt
            do {
                let locale = try await SpeechLocaleResolver.resolve(preference: "en_US")
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    preset: .timeIndexedProgressiveTranscription
                )
                try await SpeechAnalyzerService.ensureAssets(for: transcriber, locale: locale)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: input)
                _ = continuation
                attempt = ProbeAttempt(
                    started: true,
                    error: nil,
                    analyzer: analyzer,
                    inputContinuation: continuation
                )
            } catch {
                attempt = ProbeAttempt(
                    started: false,
                    error: error.localizedDescription,
                    analyzer: nil,
                    inputContinuation: nil
                )
            }
            await racer.finish(attempt)
        }
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            await racer.finish(
                ProbeAttempt(
                    started: false,
                    error: "probe timed out",
                    analyzer: nil,
                    inputContinuation: nil
                )
            )
        }
        return await racer.value()
    }

}
