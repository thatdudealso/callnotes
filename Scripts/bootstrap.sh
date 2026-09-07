#!/usr/bin/env bash
# Provision the local services CallNotes will use on a development Mac.
# Run with --check to inspect every operation without changing the machine.
# Phase 2's original PostgreSQL 16 decision was superseded by dedicated PostgreSQL 18.

set -euo pipefail

CHECK_ONLY=false
for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=true ;;
    *)
      echo "usage: $0 [--check]" >&2
      exit 64
      ;;
  esac
done

CALLNOTES_ROLE="callnotes"
CALLNOTES_DATABASE="callnotes"
CALLNOTES_POSTGRES_PORT="5433"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
POSTGRES_PLIST="$LAUNCH_AGENTS_DIR/com.thatdudealso.callnotes.postgresql.plist"

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
  <key>ProgramArguments</key><array><string>$POSTGRES_SERVER</string><string>-D</string><string>$POSTGRES_DATA_DIR</string><string>-k</string><string>$POSTGRES_SOCKET_DIR</string><string>-p</string><string>$CALLNOTES_POSTGRES_PORT</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/callnotes-postgresql.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/callnotes-postgresql.err.log</string>
</dict></plist>
EOF
}

bootstrap_launch_agent() {
  local plist="$1"
  local domain
  domain="gui/$(id -u)"
  launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$plist"
}

wait_for_postgres() {
  local _attempt
  for _attempt in {1..60}; do
    if "$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname=postgres --command="SELECT 1" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  say "PostgreSQL did not become ready"
  exit 1
}

if ! command -v brew >/dev/null 2>&1; then
  say "Homebrew is required: https://brew.sh"
  exit 1
fi

say "Installing or updating dedicated PostgreSQL 18 dependencies"
run brew install postgresql@18 pgvector

if "$CHECK_ONLY"; then
  say "would locate Homebrew's dedicated postgresql@18 and pgvector installation"
  say "would create PostgreSQL role '$CALLNOTES_ROLE', database '$CALLNOTES_DATABASE', and extensions vector + pg_trgm"
  say "would write a launchd agent for dedicated postgresql@18"
  exit 0
fi

POSTGRES_PREFIX="$(brew --prefix postgresql@18)"
PGVECTOR_PREFIX="$(brew --prefix pgvector)"
HOMEBREW_PREFIX="$(brew --prefix)"
PSQL="$POSTGRES_PREFIX/bin/psql"
CREATEDB="$POSTGRES_PREFIX/bin/createdb"
POSTGRES_SERVER="$POSTGRES_PREFIX/bin/postgres"
POSTGRES_DATA_DIR="$HOMEBREW_PREFIX/var/callnotes-postgresql@18"
POSTGRES_SOCKET_DIR="$POSTGRES_DATA_DIR/socket"

if [[ ! -f "$POSTGRES_DATA_DIR/PG_VERSION" ]]; then
  say "Initializing dedicated PostgreSQL 18 data directory at $POSTGRES_DATA_DIR"
  "$POSTGRES_PREFIX/bin/initdb" --pgdata="$POSTGRES_DATA_DIR"
fi
mkdir -p "$POSTGRES_SOCKET_DIR"

write_postgres_plist
bootstrap_launch_agent "$POSTGRES_PLIST"
wait_for_postgres

if ! "$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname=postgres --tuples-only --no-align \
  --command="SELECT 1 FROM pg_roles WHERE rolname = '$CALLNOTES_ROLE'" | grep -qx 1; then
  say "Creating PostgreSQL role $CALLNOTES_ROLE"
  "$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname=postgres --command="CREATE ROLE $CALLNOTES_ROLE LOGIN"
fi

if ! "$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname=postgres --tuples-only --no-align \
  --command="SELECT 1 FROM pg_database WHERE datname = '$CALLNOTES_DATABASE'" | grep -qx 1; then
  say "Creating PostgreSQL database $CALLNOTES_DATABASE"
  "$CREATEDB" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --owner="$CALLNOTES_ROLE" "$CALLNOTES_DATABASE"
fi

"$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname="$CALLNOTES_DATABASE" --command="CREATE EXTENSION IF NOT EXISTS vector"
"$PSQL" --host="$POSTGRES_SOCKET_DIR" --port="$CALLNOTES_POSTGRES_PORT" --dbname="$CALLNOTES_DATABASE" --command="CREATE EXTENSION IF NOT EXISTS pg_trgm"

# pgvector's extension control file is normally found by Homebrew automatically.
# Keep its prefix visible in the script output for troubleshooting mixed-prefix installs.
say "Using pgvector from $PGVECTOR_PREFIX"

say "CallNotes bootstrap complete."
