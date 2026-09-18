import Foundation

public struct RetentionSweepResult: Sendable, Equatable {
    public var deletedAudioPaths: [String]
    public var deletedCallIDs: [UUID]
    public var reclaimedBytes: Int

    public init(deletedAudioPaths: [String], deletedCallIDs: [UUID], reclaimedBytes: Int) {
        self.deletedAudioPaths = deletedAudioPaths
        self.deletedCallIDs = deletedCallIDs
        self.reclaimedBytes = reclaimedBytes
    }

    public var didReclaimDisk: Bool { reclaimedBytes > 0 || !deletedAudioPaths.isEmpty }
}

/// Deletes on-disk recordings (and optionally call rows) older than the
/// policy. Hiding a row without unlinking the CAF is not a sweep.
public struct RetentionSweeper: Sendable {
    public var policy: RetentionPolicy

    public init(policy: RetentionPolicy) {
        self.policy = policy
    }

    public func sweep(
        store: any CallStore,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> RetentionSweepResult {
        guard let cutoff = policy.cutoff(now: now) else {
            return RetentionSweepResult(deletedAudioPaths: [], deletedCallIDs: [], reclaimedBytes: 0)
        }
        let calls = try await store.fetchCalls()
        var deletedAudio: [String] = []
        var deletedCalls: [UUID] = []
        var bytes = 0
        for call in calls {
            guard isTerminal(call) else { continue }
            let ageAnchor = call.endedAt ?? call.startedAt
            guard ageAnchor < cutoff else { continue }
            if policy.deletesAudio {
                bytes += try deleteAudioFile(at: call.audioPath, fileManager: fileManager)
                if !call.audioPath.isEmpty {
                    deletedAudio.append(call.audioPath)
                }
            }
            if policy.deletesDerivedData {
                try await store.deleteCall(id: call.id)
                deletedCalls.append(call.id)
            } else if policy.deletesAudio, !call.audioPath.isEmpty {
                var cleared = call
                cleared.audioPath = ""
                try await store.upsertCall(cleared)
            }
        }
        return RetentionSweepResult(
            deletedAudioPaths: deletedAudio,
            deletedCallIDs: deletedCalls,
            reclaimedBytes: bytes
        )
    }

    private func isTerminal(_ call: Call) -> Bool {
        switch call.status {
        case .notesReady, .failed:
            true
        case .recording, .uploaded, .transcribing, .transcribed:
            false
        }
    }

    private func deleteAudioFile(at path: String, fileManager: FileManager) throws -> Int {
        guard !path.isEmpty else { return 0 }
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try fileManager.removeItem(at: url)
        return size
    }
}
