#!/usr/bin/env bash
# Provision the local services CallNotes will use on a development Mac.
# Run with --check to inspect every operation without changing the machine.

set -euo pipefail

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--check]" >&2
  exit 64
fi

CALLNOTES_ROLE="callnotes"
CALLNOTES_DATABASE="callnotes"
GLIMMER_MODEL="muse-glimmer:30b@sha256:de878ce33ad81d060001db1469a02eebe4d86f0ad58cfe52dc062fdcbe4464c1"
FALLBACK_MODEL="qwen3:30b-instruct@sha256:19e422b0231392335cfc49cfd172de7034bb1aeabb08aa307cce745c60b272fe"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
POSTGRES_PLIST="$LAUNCH_AGENTS_DIR/com.thatdudealso.callnotes.postgresql.plist"
OLLAMA_PLIST="$LAUNCH_AGENTS_DIR/com.thatdudealso.callnotes.ollama.plist"

say() { printf '%s\n' "$*"; }

run() {
  if "$CHECK_ONLY"; then
    say "would run: $*"
  else
    "$@"
  fi
}

write_postgres_plist() {

  if "$CHECK_ONLY"; then
    say "would write: $POSTGRES_PLIST (com.thatdudealso.callnotes.postgresql)"
    return
  fi

  mkdir -p "$LAUNCH_AGENTS_DIR"
  cat > "$POSTGRES_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.thatdudealso.callnotes.postgresql</string>
  <key>ProgramArguments</key><array><string>$POSTGRES_SERVER</string><string>-D</string><string>$POSTGRES_DATA_DIR</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/callnotes-postgresql.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/callnotes-postgresql.err.log</string>
</dict></plist>
EOF
}

write_ollama_plist() {
  if "$CHECK_ONLY"; then
    say "would write: $OLLAMA_PLIST (com.thatdudealso.callnotes.ollama)"
    return
  fi

  mkdir -p "$LAUNCH_AGENTS_DIR"
  cat > "$OLLAMA_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.thatdudealso.callnotes.ollama</string>
  <key>ProgramArguments</key><array><string>$(command -v ollama)</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/callnotes-ollama.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/callnotes-ollama.err.log</string>
</dict></plist>
EOF
}

if ! command -v brew >/dev/null 2>&1; then
  say "Homebrew is required: https://brew.sh"
  exit 1
fi

say "Installing or updating Homebrew dependencies"
run brew install postgresql@16 pgvector ollama tailscale

if "$CHECK_ONLY"; then
  say "would locate Homebrew's postgresql@16 and pgvector installation"
  say "would create PostgreSQL role '$CALLNOTES_ROLE', database '$CALLNOTES_DATABASE', and extensions vector + pg_trgm"
  say "would pull pinned model: $GLIMMER_MODEL"
  say "would pull pinned fallback: $FALLBACK_MODEL"
  say "would write launchd agents for postgresql@16 and ollama"
  exit 0
fi

POSTGRES_PREFIX="$(brew --prefix postgresql@16)"
PGVECTOR_PREFIX="$(brew --prefix pgvector)"
HOMEBREW_PREFIX="$(brew --prefix)"
PSQL="$POSTGRES_PREFIX/bin/psql"
CREATEDB="$POSTGRES_PREFIX/bin/createdb"
PG_CTL="$POSTGRES_PREFIX/bin/pg_ctl"
POSTGRES_SERVER="$POSTGRES_PREFIX/bin/postgres"
POSTGRES_DATA_DIR="${PGDATA:-$HOMEBREW_PREFIX/var/postgresql@16}"

if [[ ! -f "$POSTGRES_DATA_DIR/PG_VERSION" ]]; then
  say "Initializing PostgreSQL 16 data directory at $POSTGRES_DATA_DIR"
  "$POSTGRES_PREFIX/bin/initdb" --pgdata="$POSTGRES_DATA_DIR"
fi

if ! "$PG_CTL" --pgdata="$POSTGRES_DATA_DIR" status >/dev/null 2>&1; then
  say "Starting PostgreSQL 16"
  "$PG_CTL" --pgdata="$POSTGRES_DATA_DIR" --wait start
fi

if ! "$PSQL" --dbname=postgres --tuples-only --no-align \
  --command="SELECT 1 FROM pg_roles WHERE rolname = '$CALLNOTES_ROLE'" | grep -qx 1; then
  say "Creating PostgreSQL role $CALLNOTES_ROLE"
  "$PSQL" --dbname=postgres --command="CREATE ROLE $CALLNOTES_ROLE LOGIN"
fi

if ! "$PSQL" --dbname=postgres --tuples-only --no-align \
  --command="SELECT 1 FROM pg_database WHERE datname = '$CALLNOTES_DATABASE'" | grep -qx 1; then
  say "Creating PostgreSQL database $CALLNOTES_DATABASE"
  "$CREATEDB" --owner="$CALLNOTES_ROLE" "$CALLNOTES_DATABASE"
fi

"$PSQL" --dbname="$CALLNOTES_DATABASE" --command="CREATE EXTENSION IF NOT EXISTS vector"
"$PSQL" --dbname="$CALLNOTES_DATABASE" --command="CREATE EXTENSION IF NOT EXISTS pg_trgm"

# pgvector's extension control file is normally found by Homebrew automatically.
# Keep its prefix visible in the script output for troubleshooting mixed-prefix installs.
say "Using pgvector from $PGVECTOR_PREFIX"

ollama pull "$GLIMMER_MODEL"
ollama pull "$FALLBACK_MODEL"

write_postgres_plist
write_ollama_plist
launchctl bootstrap "gui/$(id -u)" "$POSTGRES_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$OLLAMA_PLIST" 2>/dev/null || true

say "CallNotes bootstrap complete. Models are pinned in docs/models.md."
