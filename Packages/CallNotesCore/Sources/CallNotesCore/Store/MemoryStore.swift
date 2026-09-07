import Foundation

/// In-memory `CallStore` for tests and for the Mac UI when Postgres is down.
public actor MemoryStore: CallStore {
    private var calls: [UUID: Call] = [:]
    private var segments: [UUID: [Segment]] = [:]
    private var profiles: [UUID: SpeakerProfile] = [:]
    private var callSpeakers: [UUID: [CallSpeaker]] = [:]
    private var samples: [SpeakerSample] = []
    private var notes: [UUID: [NotesRecord]] = [:]

    public init() {}

    public func migrate() async throws {}

    public func upsertCall(_ call: Call) async throws {
        calls[call.id] = call
    }

    public func fetchCalls() async throws -> [Call] {
        calls.values.sorted { $0.startedAt > $1.startedAt }
    }

    public func fetchCall(id: UUID) async throws -> Call? {
        calls[id]
    }

    public func replaceSegments(
        callID: UUID,
        provider: STTProviderID,
        _ newSegments: [Segment]
    ) async throws {
        let others = (segments[callID] ?? []).filter { $0.provider != provider }
        segments[callID] = others + newSegments
    }

    public func fetchSegments(callID: UUID, provider: STTProviderID?) async throws -> [Segment] {
        let all = segments[callID] ?? []
        let filtered = provider.map { id in all.filter { $0.provider == id } } ?? all
        return filtered.sorted { $0.seq < $1.seq }
    }

    public func upsertSpeakerProfile(_ profile: SpeakerProfile) async throws {
        profiles[profile.id] = profile
    }

    public func fetchSpeakerProfiles() async throws -> [SpeakerProfile] {
        Array(profiles.values)
    }

    public func replaceCallSpeakers(callID: UUID, speakers: [CallSpeaker]) async throws {
        callSpeakers[callID] = speakers.map { speaker in
            var speaker = speaker
            speaker.callID = callID
            return speaker
        }
    }

    public func fetchCallSpeakers(callID: UUID) async throws -> [CallSpeaker] {
        callSpeakers[callID] ?? []
    }

    public func insertSpeakerSample(
        profileID: UUID,
        embedding: [Float],
        embeddingModel: String,
        callID: UUID?,
        positive: Bool
    ) async throws {
        samples.append(
            SpeakerSample(
                profileID: profileID,
                embedding: embedding,
                embeddingModel: embeddingModel,
                callID: callID,
                positive: positive
            )
        )
    }

    public func upsertNotes(_ record: NotesRecord) async throws {
        var rows = notes[record.callID] ?? []
        if let index = rows.firstIndex(where: { $0.id == record.id }) {
            rows[index] = record
        } else {
            rows.append(record)
        }
        notes[record.callID] = rows
    }

    public func fetchNotes(callID: UUID) async throws -> [NotesRecord] {
        (notes[callID] ?? []).sorted { $0.createdAt > $1.createdAt }
    }
}

struct SpeakerSample: Sendable {
    var profileID: UUID
    var embedding: [Float]
    var embeddingModel: String
    var callID: UUID?
    var positive: Bool
}
