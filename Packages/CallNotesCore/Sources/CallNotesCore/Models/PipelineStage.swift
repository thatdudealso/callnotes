import Foundation

/// The pipeline step recorded on `calls.error_stage`. Raw values are the
/// wire tokens already persisted by capture, import, and notes.
public enum PipelineStage: String, Sendable, Codable, CaseIterable {
    case capture
    case audioLoad = "audio_load"
    case audioSplit = "audio_split"
    case transcription
    case stitching
    case diarization
    case attribution
    case persistence
    case notes

    public var displayName: String {
        switch self {
        case .capture: "Recording"
        case .audioLoad, .audioSplit: "Opening the recording"
        case .transcription: "Transcription"
        case .stitching: "Joining transcript chunks"
        case .diarization: "Speaker labels"
        case .attribution: "Matching speakers"
        case .persistence: "Saving"
        case .notes: "Notes"
        }
    }

    public var whatToDo: String {
        switch self {
        case .capture:
            "If a partial recording survived, Retry processes it. Otherwise take the call again."
        case .audioLoad, .audioSplit:
            "The file could not be read. Retry after CallNotes repairs the recording, or import it again."
        case .transcription:
            "Retry transcribes the saved audio. If Meta was selected, Retry falls back to local transcription."
        case .stitching, .diarization, .attribution:
            "Retry runs this stage again from the saved audio. Nothing is recaptured."
        case .persistence:
            "Retry reprocesses the saved audio because speaker mappings are not retained outside the persistence unit."
        case .notes:
            "Retry regenerates notes from the transcript already on disk."
        }
    }

    public var retryTitle: String {
        switch self {
        case .capture: "Process partial recording"
        case .persistence: "Reprocess saved recording"
        case .notes: "Retry notes"
        default: "Retry \(displayName.lowercased())"
        }
    }

    public var retryAction: FailureRetryAction {
        switch self {
        case .capture: .recoverPartial
        case .persistence: .retryPersistence
        case .notes: .regenerateNotes
        default: .retranscribe
        }
    }

    public static func resolved(_ raw: String?) -> PipelineStage? {
        guard let raw else { return nil }
        return PipelineStage(rawValue: raw)
    }
}

public enum FailureRetryAction: String, Sendable, Equatable {
    case none
    case recoverPartial
    case retranscribe
    case retryPersistence
    case regenerateNotes
}

/// Copy the detail view shows for a failed call: what broke, and the one
/// action that re-runs only that stage.
public struct FailurePresentation: Sendable, Equatable {
    public var stage: PipelineStage?
    public var headline: String
    public var detail: String
    public var actionTitle: String?
    public var action: FailureRetryAction

    public init(
        stage: PipelineStage?,
        headline: String,
        detail: String,
        actionTitle: String?,
        action: FailureRetryAction
    ) {
        self.stage = stage
        self.headline = headline
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    public static func make(error: String?, errorStage: String?, hasAudio: Bool) -> FailurePresentation {
        let stage = PipelineStage.resolved(errorStage)
        let headline = stage.map { "\($0.displayName) failed" } ?? "Could not finish"
        let recorded = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = recorded?.isEmpty == false ? recorded! : "CallNotes stopped before notes were ready."
        if let stage {
            detail += " " + stage.whatToDo
        }
        var action = stage?.retryAction ?? .none
        var title = stage?.retryTitle
        if action == .recoverPartial && !hasAudio {
            action = .none
            title = nil
            detail += " No recording file was found to process."
        }
        if action == .retranscribe && !hasAudio {
            action = .none
            title = nil
        }
        return FailurePresentation(
            stage: stage,
            headline: headline,
            detail: detail,
            actionTitle: title,
            action: action
        )
    }
}
