import Foundation

/// The notes engines CallNotes knows about.
public enum NotesProviderID: String, Codable, Sendable, CaseIterable {
    case appleFM = "apple_fm"
    case glimmer
    case fallbackInstruct = "fallback_instruct"
}

/// Style knob for notes generation (instant vs. deep).
public enum NotesStyle: Sendable {
    case instant
    case deep
}

/// A transcript handed to a notes provider.
public struct Transcript: Sendable {
    public var callID: UUID
    public var segments: [Segment]

    public init(callID: UUID, segments: [Segment]) {
        self.callID = callID
        self.segments = segments
    }
}

/// Every notes engine implements this. Glimmer is the default deep engine;
/// a proven instruct model is the automatic fallback; Apple FM does instant notes.
public protocol NotesProvider: Sendable {
    var id: NotesProviderID { get }
    func generate(_ transcript: Transcript, style: NotesStyle) async throws -> CallNotes
    func healthCheck() async -> ProviderHealth
}
