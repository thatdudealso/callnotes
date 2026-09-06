import Foundation

/// A known speaker with a voice-embedding centroid.
///
/// The embedding is produced locally (FluidAudio / WeSpeaker); provider speaker
/// tags are ephemeral, the embedding -> profile mapping is the stable identity.
public struct SpeakerProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var isOwner: Bool
    public var contactIdentifier: String?
    public var centroid: [Float]
    public var embeddingModel: String
    public var sampleCount: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        isOwner: Bool = false,
        contactIdentifier: String? = nil,
        centroid: [Float],
        embeddingModel: String,
        sampleCount: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.isOwner = isOwner
        self.contactIdentifier = contactIdentifier
        self.centroid = centroid
        self.embeddingModel = embeddingModel
        self.sampleCount = sampleCount
    }
}
