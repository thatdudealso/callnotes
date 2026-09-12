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
OLLAMA_PLIST="$LAUNCH_AGENTS_DIR/com.thatdudealso.callnotes.ollama.plist"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALLNOTES_OLLAMA_HOST="127.0.0.1:11434"
LOCAL_SIGNING_SYNC="$ROOT/Scripts/sync-local-signing.sh"
# Shared identity name and presence check live in sync-local-signing.sh.
# shellcheck disable=SC1090,SC1091
source "$LOCAL_SIGNING_SYNC"

say() { printf '%s\n' "$*"; }

run() {
  if "$CHECK_ONLY"; then
    say "would run: $*"
  else
    "$@"
  fi
}

login_keychain_path() {
  local keychain="$HOME/Library/Keychains/login.keychain-db"
  if [[ -f "$keychain" ]]; then
    printf '%s\n' "$keychain"
    return 0
  fi
  keychain="$HOME/Library/Keychains/login.keychain"
  if [[ -f "$keychain" ]]; then
    printf '%s\n' "$keychain"
    return 0
  fi
  say "login keychain not found" >&2
  return 1
}

# Self-signed identity so macOS TCC grants (Microphone, Screen & System Audio)
# survive rebuilds. Ad-hoc signatures bind the designated requirement to the
# cdhash, which changes every build. A certificate leaf does not. Local
# development only: cannot notarize or distribute.
create_local_signing_identity() {
  local work keychain p12_pass
  keychain="$(login_keychain_path)" || exit 1
  work="$(mktemp -d)"
  CALLNOTES_ROLLBACK_IMPORTED_IDENTITY=0

  # Temp key material always. After import, also roll back the login-keychain
  # identity on interrupt/`set -e` abort until trust and presence both succeed.
  # shellcheck disable=SC2064
  trap '
    if [[ "${CALLNOTES_ROLLBACK_IMPORTED_IDENTITY:-0}" == 1 ]]; then
      security delete-identity -c "'"$CALLNOTES_LOCAL_SIGNING_NAME"'" "'"$keychain"'" >/dev/null 2>&1 || true
    fi
    rm -rf "'"$work"'"
  ' EXIT
  trap 'exit 1' INT TERM

  cat > "$work/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $CALLNOTES_LOCAL_SIGNING_NAME

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 3650 -config "$work/openssl.cnf"

  # macOS Security.framework cannot read OpenSSL 3's default PKCS12 encoding
  # (AES-256-CBC + SHA-256 MAC) and fails with "MAC verification failed".
  # SHA1/3DES is what `security import` accepts.
  p12_pass="$(openssl rand -base64 24)"
  openssl pkcs12 -export \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$CALLNOTES_LOCAL_SIGNING_NAME" -out "$work/identity.p12" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
    -passout "pass:$p12_pass"

  security import "$work/identity.p12" \
    -k "$keychain" \
    -P "$p12_pass" -T /usr/bin/codesign -T /usr/bin/security
  CALLNOTES_ROLLBACK_IMPORTED_IDENTITY=1

  if ! security add-trusted-cert \
    -p codeSign -r trustRoot \
    -k "$keychain" \
    "$work/cert.pem"; then
    say "FAILED: could not trust '$CALLNOTES_LOCAL_SIGNING_NAME' for code signing"
    exit 1
  fi

  if ! callnotes_local_signing_identity_present; then
    say "FAILED: identity '$CALLNOTES_LOCAL_SIGNING_NAME' is not visible to codesign"
    exit 1
  fi

  CALLNOTES_ROLLBACK_IMPORTED_IDENTITY=0
  trap - EXIT INT TERM
  unset CALLNOTES_ROLLBACK_IMPORTED_IDENTITY
  rm -rf "$work"
}

ensure_local_signing_identity() {
  if callnotes_local_signing_identity_present; then
    say "local signing identity '$CALLNOTES_LOCAL_SIGNING_NAME': present"
    if "$CHECK_ONLY"; then
      say "would write Configs/signing.local.xcconfig"
      return
    fi
    "$LOCAL_SIGNING_SYNC"
    return
  fi

  say "local signing identity '$CALLNOTES_LOCAL_SIGNING_NAME': absent"
  if "$CHECK_ONLY"; then
    say "would create identity '$CALLNOTES_LOCAL_SIGNING_NAME' and write Configs/signing.local.xcconfig"
    return
  fi

  say "Creating local development code-signing identity '$CALLNOTES_LOCAL_SIGNING_NAME'"
  create_local_signing_identity
  "$LOCAL_SIGNING_SYNC"
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
  <key>ProgramArguments</key><array><string>$OLLAMA_BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>OLLAMA_HOST</key><string>$CALLNOTES_OLLAMA_HOST</string>
    <key>OLLAMA_KEEP_ALIVE</key><string>30m</string>
    <key>OLLAMA_NUM_PARALLEL</key><string>1</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/callnotes-ollama.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/callnotes-ollama.err.log</string>
</dict></plist>
EOF
}

wait_for_ollama() {
  local _attempt
  for _attempt in {1..60}; do
    if curl -sf "http://$CALLNOTES_OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  say "Ollama did not become ready on $CALLNOTES_OLLAMA_HOST"
  exit 1
}

pinned_notes_models() {
  CALLNOTES_ROOT="$ROOT" python3 - <<'PY'
import os, re
from pathlib import Path
text = (Path(os.environ["CALLNOTES_ROOT"]) / "docs/models.md").read_text()
for match in re.finditer(r"\|\s*`([^`]+)`\s*\|\s*`?(sha256:[0-9a-f]+)`?", text):
    print(f"{match.group(1)} {match.group(2)}")
PY
}

model_digest() {
  local name="$1"
  CALLNOTES_OLLAMA_HOST="$CALLNOTES_OLLAMA_HOST" python3 - "$name" <<'PY'
import json, sys, urllib.request
name = sys.argv[1]
url = f"http://{__import__('os').environ['CALLNOTES_OLLAMA_HOST']}/api/tags"
with urllib.request.urlopen(url, timeout=5) as response:
    data = json.load(response)
want = name[:-7] if name.endswith(":latest") else name
for model in data.get("models", []):
    found = model.get("name") or ""
    stem = found[:-7] if found.endswith(":latest") else found
    if found == name or stem == want or found == want + ":latest":
        print(model.get("digest") or "")
        break
PY
}

pull_and_verify_model() {
  local name="$1"
  local digest="$2"
  local actual
  say "Pulling $name and verifying $digest"
  run "$OLLAMA_BIN" pull "$name"
  if "$CHECK_ONLY"; then
    return
  fi
  actual="$(model_digest "$name")"
  if [[ "$actual" != "$digest" && "$actual" != "${digest#sha256:}" && "sha256:$actual" != "$digest" ]]; then
    say "digest mismatch for $name: got '${actual:-missing}' want '$digest'"
    exit 1
  fi
  say "Verified $name digest $actual"
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

ensure_local_signing_identity

say "Installing or updating dedicated PostgreSQL 18 dependencies"
run brew install postgresql@18 pgvector
say "Installing or updating Ollama"
if command -v ollama >/dev/null 2>&1 || [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
  say "Ollama already installed"
elif ! run brew install ollama; then
  say "Ollama formula install failed; trying the ollama-app cask"
  run brew install --cask ollama-app
fi

if "$CHECK_ONLY"; then
  say "would locate Homebrew's dedicated postgresql@18 and pgvector installation"
  say "would create PostgreSQL role '$CALLNOTES_ROLE', database '$CALLNOTES_DATABASE', and extensions vector + pg_trgm"
  say "would write a launchd agent for dedicated postgresql@18"
  say "would write a launchd agent for Ollama on $CALLNOTES_OLLAMA_HOST"
  if pinned_notes_models | grep -q .; then
    while read -r name digest; do
      say "would pull $name and verify $digest"
    done < <(pinned_notes_models)
  else
    say "would pull pinned notes models from docs/models.md"
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

OLLAMA_BIN="$(command -v ollama || true)"
if [[ -z "$OLLAMA_BIN" && -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
fi
if [[ -z "$OLLAMA_BIN" ]]; then
  OLLAMA_BIN="$(brew --prefix)/bin/ollama"
fi
if [[ ! -x "$OLLAMA_BIN" ]]; then
  say "Ollama binary not found after brew install"
  exit 1
fi
PATH="$(dirname "$OLLAMA_BIN"):$PATH"
export PATH

if curl -sf "http://$CALLNOTES_OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
  say "Ollama already running on $CALLNOTES_OLLAMA_HOST"
else
  write_ollama_plist
  bootstrap_launch_agent "$OLLAMA_PLIST"
  wait_for_ollama
fi

while read -r name digest; do
  pull_and_verify_model "$name" "$digest"
done < <(pinned_notes_models)

say "CallNotes bootstrap complete."
