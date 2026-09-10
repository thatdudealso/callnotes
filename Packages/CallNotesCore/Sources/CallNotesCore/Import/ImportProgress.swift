import Foundation

/// Pipeline stage shown in the import progress UI.
public enum ImportStage: String, Sendable, Codable, Equatable {
    case waiting
    case settling
    case copying
    case transcribing
    case stitching
    case notes
    case completed
    case failed
    case duplicate

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .duplicate
    }
}

/// One in-flight or finished inbox import.
public struct ImportJob: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var fileName: String
    public var sourceURL: URL
    public var stage: ImportStage
    public var chunkIndex: Int
    public var chunkCount: Int
    public var fractionComplete: Double
    public var error: String?
    public var callID: UUID?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        fileName: String,
        sourceURL: URL,
        stage: ImportStage = .waiting,
        chunkIndex: Int = 0,
        chunkCount: Int = 0,
        fractionComplete: Double = 0,
        error: String? = nil,
        callID: UUID? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.stage = stage
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.fractionComplete = fractionComplete
        self.error = error
        self.callID = callID
        self.finishedAt = finishedAt
    }

    public var statusLine: String {
        switch stage {
        case .waiting:
            "Waiting to import \(fileName)"
        case .settling:
            "Waiting for \(fileName) to finish copying"
        case .copying:
            "Copying \(fileName)"
        case .transcribing:
            if chunkCount > 1 {
                "Transcribing \(fileName) (chunk \(min(chunkIndex + 1, chunkCount)) of \(chunkCount))"
            } else {
                "Transcribing \(fileName)"
            }
        case .stitching:
            "Stitching \(fileName)"
        case .notes:
            "Notes for \(fileName)"
        case .completed:
            "Imported \(fileName)"
        case .failed:
            error ?? "Failed to import \(fileName)"
        case .duplicate:
            "Already imported \(fileName)"
        }
    }
}

/// Snapshot of every import the UI is currently showing.
public struct ImportProgress: Sendable, Equatable {
    /// How long a finished import keeps its notice on screen. Failures stay
    /// until they are dismissed; the imported call remains in history either way.
    public static let completedNoticeSeconds: TimeInterval = 4

    public var jobs: [ImportJob]

    public init(jobs: [ImportJob] = []) {
        self.jobs = jobs
    }

    public var activeJobs: [ImportJob] {
        jobs.filter { !$0.stage.isTerminal }
    }

    public var isImporting: Bool { !activeJobs.isEmpty }

    public mutating func upsert(_ job: ImportJob, now: Date = Date()) {
        let index = jobs.firstIndex { $0.id == job.id || $0.sourceURL == job.sourceURL }
        var stamped = job
        if job.stage.isTerminal {
            let existing = index.flatMap { jobs[$0].stage.isTerminal ? jobs[$0].finishedAt : nil }
            stamped.finishedAt = job.finishedAt ?? existing ?? now
        } else {
            stamped.finishedAt = nil
        }
        if let index {
            jobs[index] = stamped
        } else {
            jobs.append(stamped)
        }
        prune(now: now)
    }

    /// Drops succeeded and duplicate notices once they have been on screen long
    /// enough. Failures are kept so the reason stays readable.
    public mutating func prune(now: Date = Date()) {
        jobs.removeAll { job in
            guard job.stage == .completed || job.stage == .duplicate else { return false }
            guard let finishedAt = job.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) >= Self.completedNoticeSeconds
        }
    }

    public mutating func dismiss(_ jobID: UUID) {
        jobs.removeAll { $0.id == jobID && $0.stage.isTerminal }
    }
}
