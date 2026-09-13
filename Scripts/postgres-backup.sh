#!/usr/bin/env bash
# Dump and (optionally) restore-verify the dedicated CallNotes PostgreSQL
# instance only. Never touches port 5432 or /tmp/.s.PGSQL.5432.
set -euo pipefail

VERIFY=false
KEEP_SCRATCH=false
OUTPUT=""
for argument in "$@"; do
  case "$argument" in
    --verify) VERIFY=true ;;
    --keep-scratch) KEEP_SCRATCH=true ;;
    --output=*) OUTPUT="${argument#--output=}" ;;
    -h|--help)
      printf '%s\n' "usage: $0 [--verify] [--keep-scratch] [--output=PATH]"
      exit 0
      ;;
    *)
      echo "usage: $0 [--verify] [--keep-scratch] [--output=PATH]" >&2
      exit 64
      ;;
  esac
done

PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
SOCKET_DIR="$PREFIX/var/callnotes-postgresql@18/socket"
SOCKET="$SOCKET_DIR/.s.PGSQL.5433"
BIN="$PREFIX/opt/postgresql@18/bin"
ROLE="callnotes"
DATABASE="callnotes"
PORT="5433"
SCRATCH="callnotes_restore_verify"
ADMIN_USER="$(id -un)"

if [[ ! -S "$SOCKET" ]]; then
  echo "dedicated CallNotes Postgres socket not found: $SOCKET" >&2
  exit 1
fi
if [[ ! -x "$BIN/pg_dump" ]]; then
  echo "pg_dump not found at $BIN/pg_dump" >&2
  exit 1
fi

host_args=(--host "$SOCKET_DIR" --port "$PORT" --username "$ROLE")
admin_args=(--host "$SOCKET_DIR" --port "$PORT" --username "$ADMIN_USER")

if [[ -z "$OUTPUT" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTPUT="$HOME/Library/Application Support/CallNotes/backups/callnotes-$stamp.dump"
fi
mkdir -p "$(dirname "$OUTPUT")"

echo "dumping $DATABASE via $SOCKET_DIR port $PORT"
"$BIN/pg_dump" "${host_args[@]}" --dbname "$DATABASE" --format custom --no-owner --no-acl --file "$OUTPUT"
echo "wrote $OUTPUT"

if ! "$VERIFY"; then
  exit 0
fi

count_sql="SELECT relname || '=' || cnt::text FROM (
  SELECT 'calls'::text AS relname, count(*)::bigint AS cnt FROM calls
  UNION ALL SELECT 'segments', count(*) FROM segments
  UNION ALL SELECT 'notes', count(*) FROM notes
  UNION ALL SELECT 'speaker_profiles', count(*) FROM speaker_profiles
  UNION ALL SELECT 'call_speakers', count(*) FROM call_speakers
) counts ORDER BY relname;"

live_counts="$("$BIN/psql" "${admin_args[@]}" --dbname "$DATABASE" --tuples-only --no-align --command "$count_sql")"
echo "live counts:"
printf '%s\n' "$live_counts"

"$BIN/dropdb" "${admin_args[@]}" --if-exists "$SCRATCH"
"$BIN/createdb" "${admin_args[@]}" --owner "$ROLE" "$SCRATCH"
"$BIN/pg_restore" "${admin_args[@]}" --dbname "$SCRATCH" --no-owner --no-acl "$OUTPUT"

scratch_counts="$("$BIN/psql" "${admin_args[@]}" --dbname "$SCRATCH" --tuples-only --no-align --command "$count_sql")"
echo "scratch $SCRATCH counts:"
printf '%s\n' "$scratch_counts"

if [[ "$live_counts" != "$scratch_counts" ]]; then
  echo "restore mismatch" >&2
  echo "live:" >&2
  printf '%s\n' "$live_counts" >&2
  echo "restored:" >&2
  printf '%s\n' "$scratch_counts" >&2
  exit 1
fi

echo "restore verified against $SCRATCH"
if ! "$KEEP_SCRATCH"; then
  "$BIN/dropdb" "${admin_args[@]}" --if-exists "$SCRATCH"
fi
