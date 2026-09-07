import Foundation

/// A transcript turn after merge/normalize and speaker identity.
///
/// This is what the live pill and the history detail view render.
public struct AttributedTurn: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var channel: SegmentChannel
    public var clusterKey: String?
    public var speakerID: UUID?
    public var speakerName: String
    /// Live LS-EEND / Sortformer labels are provisional until the batch pass.
    public var isProvisional: Bool
    public var text: String
    public var words: [Word]?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        channel: SegmentChannel,
        clusterKey: String? = nil,
        speakerID: UUID? = nil,
        speakerName: String,
        isProvisional: Bool = false,
        text: String,
        words: [Word]? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.channel = channel
        self.clusterKey = clusterKey
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.isProvisional = isProvisional
        self.text = text
        self.words = words
    }
}

/// Per-call mapping from a diarization cluster to a speaker profile.
public struct CallSpeaker: Sendable, Equatable {
    public var callID: UUID
    public var clusterKey: String
    public var profileID: UUID?
    public var confidence: Float?
    public var labelOverride: String?

    public init(
        callID: UUID,
        clusterKey: String,
        profileID: UUID? = nil,
        confidence: Float? = nil,
        labelOverride: String? = nil
    ) {
        self.callID = callID
        self.clusterKey = clusterKey
        self.profileID = profileID
        self.confidence = confidence
        self.labelOverride = labelOverride
    }
}
