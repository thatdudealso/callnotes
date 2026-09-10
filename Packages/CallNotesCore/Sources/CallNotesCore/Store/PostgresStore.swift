import Foundation
import Logging
import PostgresNIO

/// PostgresNIO-backed store against the bootstrap-provisioned `callnotes` database.
public actor PostgresStore: CallStore {
    private let client: PostgresClient
    private let logger: Logger
    private var runTask: Task<Void, Never>?
    private var dashboardObservers = DashboardObservers()

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
        let transcriptionProviders = try String(
            decoding: JSONEncoder().encode(call.transcriptionProviders.map(\.rawValue)),
            as: UTF8.self
        )
        let status = call.status.rawValue
        let diarization = call.diarizationProvider
        let notes = call.notesProvider?.rawValue
        try await client.query(
            """
            INSERT INTO calls (
              id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
              audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
              transcription_providers, status, consent_announced, meta_billed_sec, error, error_stage, updated_at
            ) VALUES (
              \(call.id), \(source), \(call.startedAt), \(call.endedAt), \(call.durationSec),
              \(call.counterpartyName), \(call.counterpartyNumber), \(call.audioPath),
              \(call.audioChannels), \(call.sampleRate), \(stt), \(diarization), \(notes),
              CAST(\(transcriptionProviders) AS jsonb), \(status), \(call.consentAnnounced),
              \(call.metaBilledSec), \(call.error), \(call.errorStage), now()
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
              transcription_providers = EXCLUDED.transcription_providers,
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
        dashboardObservers.notify()
    }

    private static let selectCalls: PostgresQuery = """
        SELECT id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
               audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
               status, consent_announced, meta_billed_sec, error, error_stage, transcription_providers::text
        FROM calls
        ORDER BY started_at DESC
        """

    public func fetchCalls() async throws -> [Call] {
        try await Self.decodeCalls(client.query(Self.selectCalls, logger: logger))
    }

    private static func decodeCalls(_ rows: PostgresRowSequence) async throws -> [Call] {
        var calls: [Call] = []
        for try await row in rows {
            calls.append(try decodeCall(row))
        }
        return calls
    }

    public func fetchCall(id: UUID) async throws -> Call? {
        let rows = try await client.query(
            """
            SELECT id, source, started_at, ended_at, duration_sec, counterparty_name, counterparty_number,
                   audio_path, audio_channels, sample_rate, stt_provider, diarization_provider, notes_provider,
                   status, consent_announced, meta_billed_sec, error, error_stage, transcription_providers::text
            FROM calls WHERE id = \(id)
            """,
            logger: logger
        )
        for try await row in rows {
            return try Self.decodeCall(row)
        }
        return nil
    }

    /// Both result sets are read in one repeatable-read snapshot: an `upsertCall`
    /// interleaved between them would otherwise report a call in the totals and
    /// period rows while its contact row still shows the older count.
    public func fetchDashboardAnalytics(asOf: Date) async throws -> DashboardAnalytics {
        let logger = logger
        return try await client.withConnection { connection in
            try await connection.query("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY", logger: logger)
            do {
                let aggregate = try await Self.dashboardContacts(asOf: asOf, on: connection, logger: logger)
                let calls = try await Self.decodeCalls(connection.query(Self.selectCalls, logger: logger))
                try await connection.query("COMMIT", logger: logger)
                return DashboardAnalytics.make(
                    from: calls,
                    counterpartyNames: aggregate.resolvedNames,
                    contacts: aggregate.contacts,
                    now: asOf
                )
            } catch {
                await Self.abandonTransaction(on: connection, logger: logger)
                throw error
            }
        }
    }

    /// The rollback runs detached so a cancelled read still closes its transaction.
    /// If even that fails the connection is closed rather than returned to the pool,
    /// where a lingering read-only transaction would break the next writer.
    private static func abandonTransaction(on connection: PostgresConnection, logger: Logger) async {
        let rollback = Task.detached {
            _ = try await connection.query("ROLLBACK", logger: logger)
        }
        if (try? await rollback.value) == nil {
            try? await connection.close()
        }
    }

    public func dashboardChanges() async -> AsyncStream<Void> {
        dashboardObservers.register { [weak self] id in
            Task { await self?.removeDashboardObserver(id) }
        }
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
        for try await row in rows {
            records.append(try Self.decodeNotes(row))
        }
        return records
    }

    private static func decodeNotes(_ row: PostgresRow) throws -> NotesRecord {
        let decoded = try row.decode((UUID, UUID, String, String?, String, String, Bool, Date).self)
        return NotesRecord(
            id: decoded.0,
            callID: decoded.1,
            provider: NotesProviderID(rawValue: decoded.2) ?? .glimmer,
            modelDigest: decoded.3,
            promptVersion: decoded.4,
            body: try JSONDecoder().decode(CallNotes.self, from: Data(decoded.5.utf8)),
            editedByUser: decoded.6,
            createdAt: decoded.7
        )
    }

    public func fetchPreferredNotesByCall() async throws -> [UUID: NotesRecord] {
        let appleFM = NotesProviderID.appleFM.rawValue
        let rows = try await client.query(
            """
            SELECT DISTINCT ON (call_id)
                   id, call_id, provider, model_digest, prompt_version, body::text, edited_by_user, created_at
            FROM notes
            ORDER BY call_id, (provider = \(appleFM)), created_at DESC
            """,
            logger: logger
        )
        var records: [UUID: NotesRecord] = [:]
        for try await row in rows {
            let record = try Self.decodeNotes(row)
            records[record.callID] = record
        }
        return records
    }

    public func closeStrandedRecordings(excluding liveCallID: UUID?) async throws -> [Call] {
        let stranded = try await fetchCalls().filter {
            StrandedRecordingRepair.isStranded($0, liveCallID: liveCallID)
        }
        var repaired: [Call] = []
        for call in stranded {
            let closed = StrandedRecordingRepair.closed(
                call,
                lastSegmentEndSec: try await lastSegmentEnd(callID: call.id)
            )
            try await upsertCall(closed)
            repaired.append(closed)
        }
        return repaired
    }

    private func lastSegmentEnd(callID: UUID) async throws -> TimeInterval? {
        let rows = try await client.query(
            "SELECT max(end_sec) FROM segments WHERE call_id = \(callID)",
            logger: logger
        )
        for try await maxEnd in rows.decode(Float?.self) {
            return maxEnd.map(TimeInterval.init)
        }
        return nil
    }

    /// Deletes synthetic rows inserted by live dashboard tests. Call speakers,
    /// segments, and notes cascade from `calls`; speaker samples cascade from
    /// profiles. Always invoke from a failure path as well as the success path.
    func removeTestFixtures(callIDs: [UUID], profileIDs: [UUID] = []) async throws {
        for id in callIDs {
            try await client.query("DELETE FROM calls WHERE id = \(id)", logger: logger)
        }
        for id in profileIDs {
            try await client.query("DELETE FROM speaker_profiles WHERE id = \(id)", logger: logger)
        }
        if !callIDs.isEmpty {
            dashboardObservers.notify()
        }
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
                String?, String?, String, Bool, Int, String?, String?, String
            ).self
        )
        let transcriptionProviders = (try? JSONDecoder().decode(
            [String].self,
            from: Data(decoded.18.utf8)
        ))?.compactMap(STTProviderID.init(rawValue:)) ?? []
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
            transcriptionProviders: transcriptionProviders,
            diarizationProvider: decoded.11,
            notesProvider: decoded.12.flatMap(NotesProviderID.init(rawValue:)),
            status: CallStatus(rawValue: decoded.13) ?? .transcribed,
            consentAnnounced: decoded.14,
            metaBilledSec: decoded.15,
            error: decoded.16,
            errorStage: decoded.17
        )
    }

    private func removeDashboardObserver(_ id: UUID) {
        dashboardObservers.remove(id)
    }

    private static let incompleteProcessingStatuses = DashboardAnalytics
        .incompleteProcessingStatuses
        .map(\.rawValue)
        .sorted()

    /// Mirrors `CharacterSet.whitespacesAndNewlines` so Postgres and MemoryStore
    /// resolve and group the same identity for the same stored name.
    private static let identityWhitespace =
        " \t\n\u{0B}\u{0C}\r\u{85}\u{A0}\u{1680}"
        + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}"
        + "\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
        + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"

    /// Counts, talk time, averages and last-contacted are aggregated by Postgres so
    /// the dashboard never loads the whole call table to group it in memory. Identity
    /// resolves in the contracted order: the user-edited counterparty name, then the
    /// highest-confidence matched non-owner speaker profile, then `Unknown`, grouped
    /// case-insensitively so one person never splits across rows.
    private static func dashboardContacts(
        asOf: Date,
        on connection: PostgresConnection,
        logger: Logger
    ) async throws -> (contacts: [DashboardContact], resolvedNames: [UUID: String]) {
        let rows = try await connection.query(
            """
            WITH edited AS (
              SELECT
                calls.id AS call_id,
                calls.started_at AS started_at,
                GREATEST(0, COALESCE(
                  calls.duration_sec,
                  CASE
                    WHEN calls.ended_at IS NOT NULL
                      THEN FLOOR(EXTRACT(EPOCH FROM (calls.ended_at - calls.started_at)))::int
                    WHEN calls.status = \(CallStatus.recording.rawValue)
                      THEN FLOOR(EXTRACT(EPOCH FROM (\(asOf) - calls.started_at)))::int
                    ELSE 0
                  END
                )) AS duration_sec,
                (
                  calls.duration_sec IS NULL
                  AND calls.ended_at IS NULL
                  AND calls.status = ANY(\(Self.incompleteProcessingStatuses))
                ) AS is_incomplete,
                NULLIF(btrim(calls.counterparty_name, \(identityWhitespace)), '') AS edited_name
              FROM calls
            ),
            resolved AS (
              SELECT
                edited.call_id,
                edited.started_at,
                edited.duration_sec,
                edited.is_incomplete,
                COALESCE(
                  edited.edited_name,
                  NULLIF(btrim(matched.display_name, \(identityWhitespace)), ''),
                  'Unknown'
                ) AS resolved_name
              FROM edited
              LEFT JOIN LATERAL (
                SELECT speaker_profiles.display_name
                FROM call_speakers
                JOIN speaker_profiles ON speaker_profiles.id = call_speakers.profile_id
                WHERE call_speakers.call_id = edited.call_id
                  AND edited.edited_name IS NULL
                  AND speaker_profiles.is_owner = false
                  AND btrim(speaker_profiles.display_name, \(identityWhitespace)) <> ''
                ORDER BY call_speakers.confidence DESC NULLS LAST, speaker_profiles.display_name
                LIMIT 1
              ) AS matched ON true
            )
            SELECT
              count(*)::int AS call_count,
              sum(duration_sec)::int AS total_duration_sec,
              (sum(duration_sec) / GREATEST(1, count(*) FILTER (WHERE NOT is_incomplete)))::int
                AS average_duration_sec,
              max(started_at) AS last_contacted_at,
              array_agg(call_id ORDER BY started_at DESC, call_id) AS call_ids,
              array_agg(resolved_name ORDER BY started_at DESC, call_id) AS resolved_names
            FROM resolved
            GROUP BY lower(resolved_name)
            ORDER BY call_count DESC, last_contacted_at DESC
            """,
            logger: logger
        )
        var contacts: [DashboardContact] = []
        var resolvedNames: [UUID: String] = [:]
        for try await row in rows.decode((Int, Int, Int, Date, [UUID], [String]).self) {
            let callIDs = row.4
            let names = row.5
            for (callID, name) in zip(callIDs, names) {
                resolvedNames[callID] = name
            }
            contacts.append(
                DashboardContact(
                    name: names.first ?? "Unknown",
                    callCount: row.0,
                    totalDurationSec: row.1,
                    averageDurationSec: row.2,
                    lastContactedAt: row.3,
                    callIDs: callIDs
                )
            )
        }
        return (contacts, resolvedNames)
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
          sample_rate int DEFAULT 16000, stt_provider text NOT NULL,
          transcription_providers jsonb NOT NULL DEFAULT '[]'::jsonb, diarization_provider text, notes_provider text,
          status text CHECK (status IN ('recording','uploaded','transcribing','transcribed','notes_ready','failed')),
          consent_announced bool DEFAULT false, meta_billed_sec int DEFAULT 0, error text, error_stage text,
          created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
        CREATE INDEX IF NOT EXISTS calls_started_at_dashboard ON calls (started_at DESC);
        DROP INDEX IF EXISTS calls_counterparty_started_at_dashboard;
        DROP INDEX IF EXISTS calls_counterparty_identity_started_at_dashboard;
        CREATE TABLE IF NOT EXISTS call_speakers (
          call_id uuid REFERENCES calls ON DELETE CASCADE, cluster_key text,
          profile_id uuid REFERENCES speaker_profiles, confidence real, label_override text,
          PRIMARY KEY (call_id, cluster_key));
        CREATE TABLE IF NOT EXISTS segments (
          id bigserial PRIMARY KEY, call_id uuid REFERENCES calls ON DELETE CASCADE, seq int NOT NULL,
          start_sec real NOT NULL, end_sec real NOT NULL, channel text CHECK (channel IN ('near','far','mixed')),
          cluster_key text, text text NOT NULL, words jsonb, provider text NOT NULL,
          UNIQUE (call_id, provider, seq));
        ALTER TABLE calls
          ADD COLUMN IF NOT EXISTS transcription_providers jsonb NOT NULL DEFAULT '[]'::jsonb;
        UPDATE calls
        SET transcription_providers = COALESCE(
          (SELECT jsonb_agg(DISTINCT provider) FROM segments WHERE call_id = calls.id),
          jsonb_build_array(stt_provider))
        WHERE transcription_providers = '[]'::jsonb
          AND NOT EXISTS (
            SELECT 1 FROM schema_migrations WHERE version = 'backfill_transcription_providers');
        INSERT INTO schema_migrations (version) VALUES ('backfill_transcription_providers')
        ON CONFLICT (version) DO NOTHING;
        CREATE TABLE IF NOT EXISTS notes (
          id uuid PRIMARY KEY, call_id uuid REFERENCES calls ON DELETE CASCADE, provider text NOT NULL,
          model_digest text, prompt_version text NOT NULL, body jsonb NOT NULL,
          edited_by_user bool DEFAULT false, created_at timestamptz DEFAULT now());
        CREATE TABLE IF NOT EXISTS settings (key text PRIMARY KEY, value jsonb NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_log (device_id uuid, call_id uuid, direction text, at timestamptz DEFAULT now());
        """
}
