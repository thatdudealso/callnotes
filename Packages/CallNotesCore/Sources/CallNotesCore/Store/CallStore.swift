import Foundation

/// Persistence for calls, segments, and speaker profiles (plan section 8).
public protocol CallStore: Sendable {
    func migrate() async throws
    func upsertCall(_ call: Call) async throws
    func fetchCalls() async throws -> [Call]
    func fetchCall(id: UUID) async throws -> Call?
    func replaceSegments(callID: UUID, provider: STTProviderID, _ segments: [Segment]) async throws
    func fetchSegments(callID: UUID, provider: STTProviderID?) async throws -> [Segment]
    func upsertSpeakerProfile(_ profile: SpeakerProfile) async throws
    func fetchSpeakerProfiles() async throws -> [SpeakerProfile]
    func replaceCallSpeakers(callID: UUID, speakers: [CallSpeaker]) async throws
    func fetchCallSpeakers(callID: UUID) async throws -> [CallSpeaker]
    func insertSpeakerSample(
        profileID: UUID,
        embedding: [Float],
        embeddingModel: String,
        callID: UUID?,
        positive: Bool
    ) async throws
    func upsertNotes(_ record: NotesRecord) async throws
    func fetchNotes(callID: UUID) async throws -> [NotesRecord]
}

extension CallStore {
    public func fetchPreferredNotes(callID: UUID) async throws -> NotesRecord? {
        NotesRecord.preferred(in: try await fetchNotes(callID: callID))
    }
}

enum VectorCodec {
    static func literal(_ values: [Float]) -> String {
        "[" + values.map { String(format: "%.8f", $0) }.joined(separator: ",") + "]"
    }

    static func parse(_ text: String) -> [Float] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func pad(_ values: [Float], to dimension: Int = EmbeddingModel.dimension) -> [Float] {
        if values.count >= dimension { return Array(values.prefix(dimension)) }
        return values + Array(repeating: 0, count: dimension - values.count)
    }
}
