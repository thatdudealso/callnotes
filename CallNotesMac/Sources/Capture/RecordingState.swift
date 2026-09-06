import Foundation

/// Menu-bar icon states per plan section 10.1.
enum RecordingState: Equatable, Sendable {
    case idle
    case armed
    case recording
    case processing

    var systemImage: String {
        switch self {
        case .idle: return "phone.badge.waveform"
        case .armed: return "phone.badge.waveform.fill"
        case .recording: return "record.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        }
    }
}