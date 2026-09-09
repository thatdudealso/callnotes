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

    public init(
        id: UUID = UUID(),
        fileName: String,
        sourceURL: URL,
        stage: ImportStage = .waiting,
        chunkIndex: Int = 0,
        chunkCount: Int = 0,
        fractionComplete: Double = 0,
        error: String? = nil,
        callID: UUID? = nil
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
    public var jobs: [ImportJob]

    public init(jobs: [ImportJob] = []) {
        self.jobs = jobs
    }

    public var activeJobs: [ImportJob] {
        jobs.filter { $0.stage != .completed && $0.stage != .failed && $0.stage != .duplicate }
    }

    public var isImporting: Bool { !activeJobs.isEmpty }
}
