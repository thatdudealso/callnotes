import Foundation

/// Embedding-model provenance stored with every speaker vector (plan 6.4).
///
/// FluidAudio's WeSpeaker ResNet default is 256-d. Never cosine-compare
/// vectors produced by different models or dimensions.
public enum EmbeddingModel: Sendable {
    public static let weSpeakerV2 = "wespeaker_v2"
    public static let dimension = 256

    public static func isCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }
}
