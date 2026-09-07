import Foundation
import Logging
import PostgresNIO

/// PostgresNIO-backed store against the bootstrap-provisioned `callnotes` database.
public actor PostgresStore: CallStore {
    private let client: PostgresClient
    private let logger: Logger
    private var runTask: Task<Void, Never>?

    public init(configuration: StoreConfiguration, password: String = "") {
        var logger = Logger(label: "com.thatdudealso.callnotes.store")
        logger.logLevel = .warning
        self.logger = logger
        var clientConfiguration = configuration.clientConfiguration(password: password)
        clientConfiguration.options.connectTimeout = .seconds(2)
        self.client = PostgresClient(
            configuration: clientConfiguration,
            backgroundLogger: logger
        )
        let client = self.client
        self.runTask = Task { await client.run() }
    }

    deinit {
        runTask?.cancel()
    }

    public func migrate() async throws {
        let sql = try Self.loadMigrationSQL()
        for statement in Self.statements(from: sql) {
            do {
                try await client.query(PostgresQuery(unsafeSQL: statement), logger: logger)
            } catch {
                // CREATE EXTENSION needs a superuser; bootstrap.sh already
                // installs vector + pg_trgm as the OS postgres role.
                if statement.lowercased().contains("create extension") {
                    continue
                }
                throw error
            }
        }
        try await client.query(
            """
            INSERT INTO schema_migrations (version) VALUES ('001_initial')
            ON CONFLICT (version) DO NOTHING
            """,
            logger: logger
        )
    }

    public func upsertCall(_ call: Call) async throws {
        let source = call.source.rawValue
        let stt = call.sttProvider.rawValue
        let status = call.status.rawValue
        let diarization = call.diarizationProvider
        let notes = call.notesProvider?.rawValue
        try await client.query(
            """
            INSERT INTO calls (
              id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
              audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
              status, consent_announced, meta_billed_sec, error, error_stage, updated_at
            ) VALUES (
              \(call.id), \(source), \(call.startedAt), \(call.endedAt), \(call.durationSec),
              \(call.counterpartyName), \(call.counterpartyNumber), \(call.audioPath),
              \(call.audioChannels), \(call.sampleRate), \(stt), \(diarization), \(notes),
              \(status), \(call.consentAnnounced), \(call.metaBilledSec), \(call.error), \(call.errorStage), now()
            )
            ON CONFLICT (id) DO UPDATE SET
              source = EXCLUDED.source,
              started_at = EXCLUDED.started_at,
              ended_at = EXCLUDED.ended_at,
              duration_sec = EXCLUDED.duration_sec,
              counterparty_name = EXCLUDED.counterparty_name,
              counterparty_number = EXCLUDED.counterparty_number,
              audio_path = EXCLUDED.audio_path,
              audio_channels = EXCLUDED.audio_channels,
              sample_rate = EXCLUDED.sample_rate,
              stt_provider = EXCLUDED.stt_provider,
              diarization_provider = EXCLUDED.diarization_provider,
              notes_provider = EXCLUDED.notes_provider,
              status = EXCLUDED.status,
              consent_announced = EXCLUDED.consent_announced,
              meta_billed_sec = EXCLUDED.meta_billed_sec,
              error = EXCLUDED.error,
              error_stage = EXCLUDED.error_stage,
              updated_at = now()
            """,
            logger: logger
        )
    }

    public func fetchCalls() async throws -> [Call] {
        let rows = try await client.query(
            """
            SELECT id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
                   audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
                   status, consent_announced, meta_billed_sec, error, error_stage
            FROM calls
            ORDER BY started_at DESC
            """,
            logger: logger
        )
        var calls: [Call] = []
        for try await row in rows {
            calls.append(try Self.decodeCall(row))
        }
        return calls
    }

    public func fetchCall(id: UUID) async throws -> Call? {
        let rows = try await client.query(
            """
            SELECT id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
                   audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
                   status, consent_announced, meta_billed_sec, error, error_stage
            FROM calls WHERE id = \(id)
            """,
            logger: logger
        )
        for try await row in rows {
            return try Self.decodeCall(row)
        }
        return nil
    }

    public func replaceSegments(
        callID: UUID,
        provider: STTProviderID,
        _ segments: [Segment]
    ) async throws {
        let providerValue = provider.rawValue
        try await client.query(
            "DELETE FROM segments WHERE call_id = \(callID) AND provider = \(providerValue)",
            logger: logger
        )
        for segment in segments {
            let wordsJSON: String?
            if let words = segment.words {
                wordsJSON = String(data: try JSONEncoder().encode(words), encoding: .utf8)
            } else {
                wordsJSON = nil
            }
            let channel = segment.channel.rawValue
            try await client.query(
                """
                INSERT INTO segments (call_id, seq, start_sec, end_sec, channel, cluster_key, text, words, provider)
                VALUES (
                  \(segment.callID), \(segment.seq), \(Float(segment.startSec)), \(Float(segment.endSec)),
                  \(channel), \(segment.clusterKey), \(segment.text), CAST(\(wordsJSON) AS jsonb), \(providerValue)
                )
                """,
                logger: logger
            )
        }
    }

    public func fetchSegments(callID: UUID, provider: STTProviderID?) async throws -> [Segment] {
        let rows: PostgresRowSequence
        if let provider {
            let providerValue = provider.rawValue
            rows = try await client.query(
                """
                SELECT call_id, seq, start_sec, end_sec, channel, cluster_key, text, words::text, provider
                FROM segments WHERE call_id = \(callID) AND provider = \(providerValue)
                ORDER BY seq
                """,
                logger: logger
            )
        } else {
            rows = try await client.query(
                """
                SELECT call_id, seq, start_sec, end_sec, channel, cluster_key, text, words::text, provider
                FROM segments WHERE call_id = \(callID)
                ORDER BY seq
                """,
                logger: logger
            )
        }
        var segments: [Segment] = []
        for try await row in rows {
            segments.append(try Self.decodeSegment(row))
        }
        return segments
    }

    public func upsertSpeakerProfile(_ profile: SpeakerProfile) async throws {
        let literal = VectorCodec.literal(VectorCodec.pad(profile.centroid))
        try await client.query(
            """
            INSERT INTO speaker_profiles (id, display_name, is_owner, contact_identifier, centroid, embedding_model, sample_count)
            VALUES (
              \(profile.id), \(profile.displayName), \(profile.isOwner), \(profile.contactIdentifier),
              CAST(\(literal) AS vector), \(profile.embeddingModel), \(profile.sampleCount)
            )
            ON CONFLICT (id) DO UPDATE SET
              display_name = EXCLUDED.display_name,
              is_owner = EXCLUDED.is_owner,
              contact_identifier = EXCLUDED.contact_identifier,
              centroid = EXCLUDED.centroid,
              embedding_model = EXCLUDED.embedding_model,
              sample_count = EXCLUDED.sample_count
            """,
            logger: logger
        )
    }

    public func fetchSpeakerProfiles() async throws -> [SpeakerProfile] {
        let rows = try await client.query(
            """
            SELECT id, display_name, is_owner, contact_identifier, centroid::text, embedding_model, sample_count
            FROM speaker_profiles
            """,
            logger: logger
        )
        var profiles: [SpeakerProfile] = []
        for try await (
            id,
            displayName,
            isOwner,
            contact,
            centroidText,
            model,
            sampleCount
        ) in rows.decode((UUID, String, Bool, String?, String, String, Int).self) {
            profiles.append(
                SpeakerProfile(
                    id: id,
                    displayName: displayName,
                    isOwner: isOwner,
                    contactIdentifier: contact,
                    centroid: VectorCodec.parse(centroidText),
                    embeddingModel: model,
                    sampleCount: sampleCount
                )
            )
        }
        return profiles
    }

    public func replaceCallSpeakers(callID: UUID, speakers: [CallSpeaker]) async throws {
        try await client.query("DELETE FROM call_speakers WHERE call_id = \(callID)", logger: logger)
        for speaker in speakers {
            try await client.query(
                """
                INSERT INTO call_speakers (call_id, cluster_key, profile_id, confidence, label_override)
                VALUES (\(callID), \(speaker.clusterKey), \(speaker.profileID), \(speaker.confidence), \(speaker.labelOverride))
                """,
                logger: logger
            )
        }
    }

    public func fetchCallSpeakers(callID: UUID) async throws -> [CallSpeaker] {
        let rows = try await client.query(
            """
            SELECT call_id, cluster_key, profile_id, confidence, label_override
            FROM call_speakers WHERE call_id = \(callID)
            """,
            logger: logger
        )
        var speakers: [CallSpeaker] = []
        for try await (callID, clusterKey, profileID, confidence, label) in rows.decode(
            (UUID, String, UUID?, Float?, String?).self
        ) {
            speakers.append(
                CallSpeaker(
                    callID: callID,
                    clusterKey: clusterKey,
                    profileID: profileID,
                    confidence: confidence,
                    labelOverride: label
                )
            )
        }
        return speakers
    }

    public func insertSpeakerSample(
        profileID: UUID,
        embedding: [Float],
        embeddingModel: String,
        callID: UUID?,
        positive: Bool
    ) async throws {
        let literal = VectorCodec.literal(VectorCodec.pad(embedding))
        try await client.query(
            """
            INSERT INTO speaker_samples (id, profile_id, embedding, embedding_model, call_id, positive)
            VALUES (\(UUID()), \(profileID), CAST(\(literal) AS vector), \(embeddingModel), \(callID), \(positive))
            """,
            logger: logger
        )
    }

    public func upsertNotes(_ record: NotesRecord) async throws {
        let provider = record.provider.rawValue
        let body = String(data: try JSONEncoder().encode(record.body), encoding: .utf8)
        try await client.query(
            """
            INSERT INTO notes (id, call_id, provider, model_digest, prompt_version, body, edited_by_user, created_at)
            VALUES (
              \(record.id), \(record.callID), \(provider), \(record.modelDigest), \(record.promptVersion),
              CAST(\(body) AS jsonb), \(record.editedByUser), \(record.createdAt)
            )
            ON CONFLICT (id) DO UPDATE SET
              provider = EXCLUDED.provider,
              model_digest = EXCLUDED.model_digest,
              prompt_version = EXCLUDED.prompt_version,
              body = EXCLUDED.body,
              edited_by_user = EXCLUDED.edited_by_user
            """,
            logger: logger
        )
    }

    public func fetchNotes(callID: UUID) async throws -> [NotesRecord] {
        let rows = try await client.query(
            """
            SELECT id, call_id, provider, model_digest, prompt_version, body::text, edited_by_user, created_at
            FROM notes WHERE call_id = \(callID)
            ORDER BY created_at DESC
            """,
            logger: logger
        )
        var records: [NotesRecord] = []
        for try await (
            id,
            callID,
            provider,
            digest,
            promptVersion,
            bodyJSON,
            edited,
            createdAt
        ) in rows.decode((UUID, UUID, String, String?, String, String, Bool, Date).self) {
            let body = try JSONDecoder().decode(CallNotes.self, from: Data(bodyJSON.utf8))
            records.append(
                NotesRecord(
                    id: id,
                    callID: callID,
                    provider: NotesProviderID(rawValue: provider) ?? .glimmer,
                    modelDigest: digest,
                    promptVersion: promptVersion,
                    body: body,
                    editedByUser: edited,
                    createdAt: createdAt
                )
            )
        }
        return records
    }

    public static func makeIfAvailable() async -> PostgresStore? {
        let candidates = StoreConfiguration.localCandidates()
        var seen = Set<String>()
        for candidate in candidates {
            let key = candidate.unixSocketPath ?? "\(candidate.host):\(candidate.port)"
            if !seen.insert(key).inserted { continue }
            if let store = await probe(candidate) {
                return store
            }
        }
        return nil
    }

    private static func probe(_ configuration: StoreConfiguration) async -> PostgresStore? {
        await withTaskGroup(of: PostgresStore?.self) { group in
            group.addTask {
                let store = PostgresStore(configuration: configuration)
                do {
                    try await store.migrate()
                    return store
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func statements(from sql: String) -> [String] {
        sql.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
    }

    private static func loadMigrationSQL() throws -> String {
        if let url = Bundle.module.url(forResource: "001_initial", withExtension: "sql") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return Self.embeddedMigrationSQL
    }

    private static func decodeCall(_ row: PostgresRow) throws -> Call {
        let decoded = try row.decode(
            (
                UUID, String, Date, Date?, Int?, String?, String?, String, Int, Int, String,
                String?, String?, String, Bool, Int, String?, String?
            ).self
        )
        return Call(
            id: decoded.0,
            source: CallSource(rawValue: decoded.1) ?? .fileImport,
            startedAt: decoded.2,
            endedAt: decoded.3,
            durationSec: decoded.4,
            counterpartyName: decoded.5,
            counterpartyNumber: decoded.6,
            audioPath: decoded.7,
            audioChannels: decoded.8,
            sampleRate: decoded.9,
            sttProvider: STTProviderID(rawValue: decoded.10) ?? .appleSpeech,
            diarizationProvider: decoded.11,
            notesProvider: decoded.12.flatMap(NotesProviderID.init(rawValue:)),
            status: CallStatus(rawValue: decoded.13) ?? .transcribed,
            consentAnnounced: decoded.14,
            metaBilledSec: decoded.15,
            error: decoded.16,
            errorStage: decoded.17
        )
    }

    private static func decodeSegment(_ row: PostgresRow) throws -> Segment {
        let decoded = try row.decode(
            (UUID, Int, Float, Float, String, String?, String, String?, String).self
        )
        let words: [Word]?
        if let json = decoded.7, let data = json.data(using: .utf8) {
            words = try? JSONDecoder().decode([Word].self, from: data)
        } else {
            words = nil
        }
        return Segment(
            callID: decoded.0,
            seq: decoded.1,
            startSec: TimeInterval(decoded.2),
            endSec: TimeInterval(decoded.3),
            channel: SegmentChannel(rawValue: decoded.4) ?? .mixed,
            clusterKey: decoded.5,
            text: decoded.6,
            words: words,
            provider: STTProviderID(rawValue: decoded.8) ?? .appleSpeech
        )
    }

    /// Fallback when the SQL resource is missing from the module bundle.
    static let embeddedMigrationSQL = """
        CREATE EXTENSION IF NOT EXISTS vector;
        CREATE EXTENSION IF NOT EXISTS pg_trgm;
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version text PRIMARY KEY,
          applied_at timestamptz NOT NULL DEFAULT now()
        );
        CREATE TABLE IF NOT EXISTS devices (
          id uuid PRIMARY KEY, name text NOT NULL, kind text CHECK (kind IN ('mac','iphone')),
          token_hash bytea NOT NULL, paired_at timestamptz NOT NULL, last_seen_at timestamptz, revoked_at timestamptz);
        CREATE TABLE IF NOT EXISTS speaker_profiles (
          id uuid PRIMARY KEY, display_name text NOT NULL, is_owner bool DEFAULT false,
          contact_identifier text, centroid vector(256) NOT NULL, embedding_model text NOT NULL,
          sample_count int DEFAULT 0, created_at timestamptz DEFAULT now());
        CREATE TABLE IF NOT EXISTS speaker_samples (
          id uuid PRIMARY KEY, profile_id uuid REFERENCES speaker_profiles ON DELETE CASCADE,
          embedding vector(256) NOT NULL, embedding_model text NOT NULL, call_id uuid, positive bool DEFAULT true,
          created_at timestamptz DEFAULT now());
        CREATE TABLE IF NOT EXISTS calls (
          id uuid PRIMARY KEY,
          source text CHECK (source IN ('mac_facetime','mac_phone','mac_manual','iphone_recording','iphone_meeting','iphone_speaker','import')),
          device_id uuid REFERENCES devices, started_at timestamptz NOT NULL, ended_at timestamptz, duration_sec int,
          counterparty_name text, counterparty_number text, audio_path text NOT NULL, audio_channels int DEFAULT 2,
          sample_rate int DEFAULT 16000, stt_provider text NOT NULL, diarization_provider text, notes_provider text,
          status text CHECK (status IN ('recording','uploaded','transcribing','transcribed','notes_ready','failed')),
          consent_announced bool DEFAULT false, meta_billed_sec int DEFAULT 0, error text, error_stage text,
          created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
        CREATE TABLE IF NOT EXISTS call_speakers (
          call_id uuid REFERENCES calls ON DELETE CASCADE, cluster_key text,
          profile_id uuid REFERENCES speaker_profiles, confidence real, label_override text,
          PRIMARY KEY (call_id, cluster_key));
        CREATE TABLE IF NOT EXISTS segments (
          id bigserial PRIMARY KEY, call_id uuid REFERENCES calls ON DELETE CASCADE, seq int NOT NULL,
          start_sec real NOT NULL, end_sec real NOT NULL, channel text CHECK (channel IN ('near','far','mixed')),
          cluster_key text, text text NOT NULL, words jsonb, provider text NOT NULL,
          UNIQUE (call_id, provider, seq));
        CREATE TABLE IF NOT EXISTS notes (
          id uuid PRIMARY KEY, call_id uuid REFERENCES calls ON DELETE CASCADE, provider text NOT NULL,
          model_digest text, prompt_version text NOT NULL, body jsonb NOT NULL,
          edited_by_user bool DEFAULT false, created_at timestamptz DEFAULT now());
        CREATE TABLE IF NOT EXISTS settings (key text PRIMARY KEY, value jsonb NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_log (device_id uuid, call_id uuid, direction text, at timestamptz DEFAULT now());
        """
}
