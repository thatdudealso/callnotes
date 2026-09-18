import Foundation

public struct RecoveredRecording: Sendable, Equatable {
    public var call: Call
    public var audioURL: URL
    public var repairedHeader: Bool
    public var createdCall: Bool

    public init(call: Call, audioURL: URL, repairedHeader: Bool, createdCall: Bool) {
        self.call = call
        self.audioURL = audioURL
        self.repairedHeader = repairedHeader
        self.createdCall = createdCall
    }
}

/// Finds capture CAF files left behind by a crash, repairs their headers, and
/// upserts a processable call row so hang-up transcription can run.
public enum PartialRecordingRecovery: Sendable {
    public static func recover(
        audioDirectory: URL,
        store: any CallStore,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) async throws -> [RecoveredRecording] {
        let contents = try fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var recovered: [RecoveredRecording] = []
        for url in contents where url.pathExtension.lowercased() == "caf" {
            guard CAFHeaderRepair.isRepairableCAF(url) else { continue }
            let repaired = (try? CAFHeaderRepair.repairIfNeeded(url)) ?? false
            guard let channels = try? StereoCAFReader.read(url), !channels.near.isEmpty else {
                continue
            }
            let duration = Double(channels.near.count) / max(channels.sampleRate, 1)
            guard duration > 0.05 else { continue }
            let resolved = url.resolvingSymlinksInPath()
            let callID = uuid(fromFile: resolved) ?? UUID()
            let existing = try await store.fetchCall(id: callID)
            if let existing, !needsRecovery(existing) {
                continue
            }
            var call = existing ?? Call(
                id: callID,
                source: .macManual,
                startedAt: now.addingTimeInterval(-duration),
                audioPath: resolved.path,
                sampleRate: Int(channels.sampleRate.rounded()),
                sttProvider: .appleSpeech,
                status: .uploaded
            )
            call.audioPath = resolved.path
            call.endedAt = call.startedAt.addingTimeInterval(duration)
            call.durationSec = Int(duration.rounded(.down))
            call.sampleRate = Int(channels.sampleRate.rounded())
            if call.status == .recording || PipelineStage.resolved(call.errorStage) == .capture {
                call.status = .uploaded
                call.error = nil
                call.errorStage = nil
            }
            try await store.upsertCall(call)
            recovered.append(
                RecoveredRecording(
                    call: call,
                    audioURL: resolved,
                    repairedHeader: repaired,
                    createdCall: existing == nil
                )
            )
        }
        return recovered
    }

    public static func uuid(fromFile url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    public static func needsRecovery(_ call: Call) -> Bool {
        switch call.status {
        case .recording, .uploaded:
            return true
        case .failed:
            return PipelineStage.resolved(call.errorStage) == .capture
        case .transcribing, .transcribed, .notesReady:
            return false
        }
    }

    public static func hasProcessableAudio(path: String, fileManager: FileManager = .default) -> Bool {
        guard !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path), CAFHeaderRepair.isRepairableCAF(url) else {
            return false
        }
        _ = try? CAFHeaderRepair.repairIfNeeded(url)
        guard let channels = try? StereoCAFReader.read(url) else { return false }
        return !channels.near.isEmpty
    }
}
