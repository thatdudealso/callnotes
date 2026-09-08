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
    public var speakerNames: [String: String]
    public var counterpartyName: String?

    public init(
        callID: UUID,
        segments: [Segment],
        speakerNames: [String: String] = [:],
        counterpartyName: String? = nil
    ) {
        self.callID = callID
        self.segments = segments
        self.speakerNames = speakerNames
        self.counterpartyName = counterpartyName
    }

    public init(callID: UUID, turns: [AttributedTurn], provider: STTProviderID, counterpartyName: String? = nil) {
        self.callID = callID
        self.segments = turns.enumerated().map { index, turn in
            Segment(
                callID: callID,
                seq: index,
                startSec: turn.start,
                endSec: turn.end,
                channel: turn.channel,
                clusterKey: turn.clusterKey,
                text: turn.text,
                words: turn.words,
                provider: provider
            )
        }
        var names: [String: String] = [:]
        for turn in turns {
            names[turn.channel.rawValue] = turn.speakerName
            if let key = turn.clusterKey {
                names[key] = turn.speakerName
            }
        }
        self.speakerNames = names
        self.counterpartyName = counterpartyName
    }

    public func labeledLines() -> [String] {
        segments
            .sorted { $0.startSec < $1.startSec }
            .map { segment in
                let key = segment.clusterKey ?? segment.channel.rawValue
                let name = speakerNames[key] ?? speakerNames[segment.channel.rawValue] ?? key
                return "\(name): \(segment.text)"
            }
    }

    public func dialogueText() -> String {
        labeledLines().joined(separator: "\n")
    }
}

/// Every notes engine implements this. Glimmer is the default deep engine;
/// a proven instruct model is the automatic fallback; Apple FM does instant notes.
public protocol NotesProvider: Sendable {
    var id: NotesProviderID { get }
    func generate(_ transcript: Transcript, style: NotesStyle) async throws -> CallNotes
    func healthCheck() async -> ProviderHealth
}
