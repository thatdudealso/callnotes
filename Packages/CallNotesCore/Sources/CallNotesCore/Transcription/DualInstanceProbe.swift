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
        let near = attempts.first ?? ProbeAttempt(started: false, error: "probe timed out", analyzer: nil)
        let far = attempts.count > 1
            ? attempts[1]
            : ProbeAttempt(started: false, error: "probe timed out", analyzer: nil)
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

    private struct ProbeAttempt {
        var started: Bool
        var error: String?
        var analyzer: SpeechAnalyzer?
    }

    private static func startProbeAnalyzer(timeout: TimeInterval) async -> ProbeAttempt {
        await withTaskGroup(of: ProbeAttempt.self) { group in
            group.addTask {
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
                    return ProbeAttempt(started: true, error: nil, analyzer: analyzer)
                } catch {
                    return ProbeAttempt(started: false, error: error.localizedDescription, analyzer: nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return ProbeAttempt(started: false, error: "probe timed out", analyzer: nil)
            }
            let first = await group.next()
                ?? ProbeAttempt(started: false, error: "probe timed out", analyzer: nil)
            group.cancelAll()
            return first
        }
    }

}
