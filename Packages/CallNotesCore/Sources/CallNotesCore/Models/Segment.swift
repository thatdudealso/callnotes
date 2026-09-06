import Foundation

/// Which capture channel a segment came from.
public enum SegmentChannel: String, Codable, Sendable {
    case near
    case far
    case mixed
}

/// One word with its timestamp, when the provider supplies word timing.
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A finalized transcript segment persisted to the `segments` table.
public struct Segment: Codable, Sendable, Equatable {
    public var callID: UUID
    public var seq: Int
    public var startSec: TimeInterval
    public var endSec: TimeInterval
    public var channel: SegmentChannel
    public var clusterKey: String?
    public var text: String
    public var words: [Word]?
    public var provider: STTProviderID

    public init(
        callID: UUID,
        seq: Int,
        startSec: TimeInterval,
        endSec: TimeInterval,
        channel: SegmentChannel,
        clusterKey: String? = nil,
        text: String,
        words: [Word]? = nil,
        provider: STTProviderID
    ) {
        self.callID = callID
        self.seq = seq
        self.startSec = startSec
        self.endSec = endSec
        self.channel = channel
        self.clusterKey = clusterKey
        self.text = text
        self.words = words
        self.provider = provider
    }
}
