CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  kind text CHECK (kind IN ('mac','iphone')),
  token_hash bytea NOT NULL,
  paired_at timestamptz NOT NULL,
  last_seen_at timestamptz,
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS speaker_profiles (
  id uuid PRIMARY KEY,
  display_name text NOT NULL,
  is_owner bool DEFAULT false,
  contact_identifier text,
  centroid vector(256) NOT NULL,
  embedding_model text NOT NULL,
  sample_count int DEFAULT 0,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS speaker_profiles_centroid_hnsw
  ON speaker_profiles USING hnsw (centroid vector_cosine_ops);

CREATE TABLE IF NOT EXISTS speaker_samples (
  id uuid PRIMARY KEY,
  profile_id uuid REFERENCES speaker_profiles ON DELETE CASCADE,
  embedding vector(256) NOT NULL,
  embedding_model text NOT NULL,
  call_id uuid,
  positive bool DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS calls (
  id uuid PRIMARY KEY,
  source text CHECK (source IN ('mac_facetime','mac_phone','mac_manual','iphone_recording','iphone_meeting','iphone_speaker','import')),
  device_id uuid REFERENCES devices,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  duration_sec int,
  counterparty_name text,
  counterparty_number text,
  audio_path text NOT NULL,
  audio_channels int DEFAULT 2,
  sample_rate int DEFAULT 16000,
  stt_provider text NOT NULL,
  diarization_provider text,
  notes_provider text,
  status text CHECK (status IN ('recording','uploaded','transcribing','transcribed','notes_ready','failed')),
  consent_announced bool DEFAULT false,
  meta_billed_sec int DEFAULT 0,
  error text,
  error_stage text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS call_speakers (
  call_id uuid REFERENCES calls ON DELETE CASCADE,
  cluster_key text,
  profile_id uuid REFERENCES speaker_profiles,
  confidence real,
  label_override text,
  PRIMARY KEY (call_id, cluster_key)
);

CREATE TABLE IF NOT EXISTS segments (
  id bigserial PRIMARY KEY,
  call_id uuid REFERENCES calls ON DELETE CASCADE,
  seq int NOT NULL,
  start_sec real NOT NULL,
  end_sec real NOT NULL,
  channel text CHECK (channel IN ('near','far','mixed')),
  cluster_key text,
  text text NOT NULL,
  words jsonb,
  provider text NOT NULL,
  UNIQUE (call_id, provider, seq)
);
CREATE INDEX IF NOT EXISTS segments_text_trgm ON segments USING gin (text gin_trgm_ops);

CREATE TABLE IF NOT EXISTS notes (
  id uuid PRIMARY KEY,
  call_id uuid REFERENCES calls ON DELETE CASCADE,
  provider text NOT NULL,
  model_digest text,
  prompt_version text NOT NULL,
  body jsonb NOT NULL,
  edited_by_user bool DEFAULT false,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_log (
  device_id uuid,
  call_id uuid,
  direction text,
  at timestamptz DEFAULT now()
);
