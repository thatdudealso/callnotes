import Foundation

/// In-memory `CallStore` for tests and for the Mac UI when Postgres is down.
public actor MemoryStore: CallStore {
    private var calls: [UUID: Call] = [:]
    private var segments: [UUID: [Segment]] = [:]
    private var profiles: [UUID: SpeakerProfile] = [:]
    private var callSpeakers: [UUID: [CallSpeaker]] = [:]
    private var samples: [SpeakerSample] = []
    private var notes: [UUID: [NotesRecord]] = [:]
    private var dashboardObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public func migrate() async throws {}

    public func upsertCall(_ call: Call) async throws {
        calls[call.id] = call
        notifyDashboardObservers()
    }

    public func fetchCalls() async throws -> [Call] {
        calls.values.sorted { $0.startedAt > $1.startedAt }
    }

    public func fetchCall(id: UUID) async throws -> Call? {
        calls[id]
    }

    public func fetchDashboardAnalytics(asOf: Date) async throws -> DashboardAnalytics {
        DashboardAnalytics.make(
            from: Array(calls.values),
            counterpartyNames: dashboardCounterpartyNames(),
            now: asOf
        )
    }

    public func dashboardChanges() async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDashboardObserver(id) }
        }
        dashboardObservers[id] = continuation
        return stream
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

    private func removeDashboardObserver(_ id: UUID) {
        dashboardObservers.removeValue(forKey: id)
    }

    private func notifyDashboardObservers() {
        for continuation in dashboardObservers.values {
            continuation.yield()
        }
    }

    private func dashboardCounterpartyNames() -> [UUID: String] {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.key, $0.value) })
        var names: [UUID: String] = [:]
        for (callID, speakers) in callSpeakers {
            guard let call = calls[callID], !hasCounterpartyName(call) else { continue }
            let matches = speakers.compactMap { speaker -> (String, Float)? in
                guard let profileID = speaker.profileID,
                    let profile = profilesByID[profileID],
                    !profile.isOwner,
                    !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (profile.displayName, speaker.confidence ?? 0)
            }
            if let match = matches.sorted(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
            }).first {
                names[callID] = match.0
            }
        }
        return names
    }

    private func hasCounterpartyName(_ call: Call) -> Bool {
        guard let name = call.counterpartyName else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SpeakerSample: Sendable {
    var profileID: UUID
    var embedding: [Float]
    var embeddingModel: String
    var callID: UUID?
    var positive: Bool
}
