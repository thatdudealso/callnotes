import Foundation

/// Menu-bar icon states per plan section 10.1.
enum RecordingState: Equatable, Sendable {
    case idle
    case armed
    case recording
    case processing

    /// Asset-catalog image of the shipped diary-facing-voices mark.
    /// Idle is outline, armed is filled; recording and processing keep that
    /// filled mark and layer the red-dot or spinner cue on top.
    var menuBarImage: String {
        switch self {
        case .idle: return "CallNotesMark"
        case .armed: return "CallNotesMarkFill"
        case .recording: return "CallNotesMarkRecording"
        case .processing: return "CallNotesMarkProcessing"
        }
    }
}
