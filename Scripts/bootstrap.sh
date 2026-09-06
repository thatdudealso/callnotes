#!/usr/bin/env bash
# Provision the local services CallNotes will use on a development Mac.
# Run with --check to inspect every operation without changing the machine.
# Phase 2's original PostgreSQL 16 decision was superseded by dedicated PostgreSQL 18.

set -euo pipefail

CHECK_ONLY=false
INSTALL_OLLAMA=false
for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=true ;;
    --with-ollama) INSTALL_OLLAMA=true ;;
    *)
      echo "usage: $0 [--check] [--with-ollama]" >&2
      exit 64
      ;;
  esac
done

CALLNOTES_ROLE="callnotes"
CALLNOTES_DATABASE="callnotes"
CALLNOTES_POSTGRES_PORT="5433"
GLIMMER_MODEL="muse-glimmer:30b"
GLIMMER_MANIFEST_DIGEST="sha256:de878ce33ad81d060001db1469a02eebe4d86f0ad58cfe52dc062fdcbe4464c1"
FALLBACK_MODEL="qwen3:30b-instruct"
FALLBACK_MANIFEST_DIGEST="sha256:19e422b0231392335cfc49cfd172de7034bb1aeabb08aa307cce745c60b272fe"
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
  <key>ProgramArguments</key><array><string>$POSTGRES_SERVER</string><string>-D</string><string>$POSTGRES_DATA_DIR</string><string>-k</string><string>$POSTGRES_SOCKET_DIR</string><string>-p</string><string>$CALLNOTES_POSTGRES_PORT</string></array>
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

wait_for_ollama() {
  local _attempt
  for _attempt in {1..60}; do
    if curl --connect-timeout 1 --max-time 2 --fail --silent --output /dev/null http://127.0.0.1:11434/api/tags; then
      return
    fi
    sleep 1
  done
  say "Ollama did not become ready"
  exit 1
}

model_manifest_digest() {
  local model="$1"
  local tags_file
  local index=0
  local name
  local digest
  tags_file="$(mktemp)"
  curl --fail --silent http://127.0.0.1:11434/api/tags > "$tags_file"
  plutil -convert xml1 "$tags_file"

  while name="$(/usr/libexec/PlistBuddy -c "Print :models:$index:name" "$tags_file" 2>/dev/null)"; do
    if [[ "$name" == "$model" ]]; then
      digest="$(/usr/libexec/PlistBuddy -c "Print :models:$index:digest" "$tags_file")"
      rm -f "$tags_file"
      say "sha256:$digest"
      return
    fi
    ((index += 1))
  done

  rm -f "$tags_file"
  say "No locally installed manifest found for $model" >&2
  return 1
}

pull_and_verify_model() {
  local model="$1"
  local expected_digest="$2"
  local actual_digest
  ollama pull "$model"
  actual_digest="$(model_manifest_digest "$model")"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    say "Manifest digest mismatch for $model: expected $expected_digest, got $actual_digest" >&2
    return 1
  fi
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
  if "$INSTALL_OLLAMA"; then
    say "would install ollama"
    say "would pull model: $GLIMMER_MODEL and verify manifest $GLIMMER_MANIFEST_DIGEST"
    say "would pull fallback: $FALLBACK_MODEL and verify manifest $FALLBACK_MANIFEST_DIGEST"
    say "would write a launchd agent for ollama"
  fi
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

if "$INSTALL_OLLAMA"; then
  run brew install ollama
  write_ollama_plist
  bootstrap_launch_agent "$OLLAMA_PLIST"
  wait_for_ollama
  pull_and_verify_model "$GLIMMER_MODEL" "$GLIMMER_MANIFEST_DIGEST"
  pull_and_verify_model "$FALLBACK_MODEL" "$FALLBACK_MANIFEST_DIGEST"
fi

say "CallNotes bootstrap complete."
