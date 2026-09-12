#!/usr/bin/env bash
# Behavioral checks for the local development code-signing identity.
# Exercises Scripts/sync-local-signing.sh and Scripts/bootstrap.sh's
# create_local_signing_identity against a throwaway keychain file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOME="${HOME}"
REAL_LOGIN="${REAL_HOME}/Library/Keychains/login.keychain-db"
failures=0
runtime_build_dir=""
runtime_pid=""
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

# create-keychain appends to the user search list. Always pin it back to the
# real login keychain by absolute path — never replay `security list-keychains`
# output, which is whitespace-quoted and unsafe to round-trip.
pin_user_keychains() {
  security list-keychains -d user -s "$REAL_LOGIN" >/dev/null
}
cleanup() {
  if [[ -n "$runtime_pid" ]] && kill -0 "$runtime_pid" 2>/dev/null; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  [[ -z "$runtime_build_dir" ]] || rm -rf "$runtime_build_dir"
  pin_user_keychains
}
trap cleanup EXIT
pin_user_keychains

assert_real_identity_present() {
  if ! security find-identity -v -p codesigning "$REAL_LOGIN" 2>/dev/null \
      | grep -F '"CallNotes Local Signing"' >/dev/null; then
    fail "login-keychain identity missing"
    return 1
  fi
}

# --- overlay writer ----------------------------------------------------------

overlay="$ROOT/Configs/signing.local.xcconfig"
rm -f "$overlay"

out="$(CALLNOTES_LOCAL_SIGNING=0 "$ROOT/Scripts/sync-local-signing.sh")"
if [[ "$out" == *"disabled via CALLNOTES_LOCAL_SIGNING"* ]] && [[ ! -f "$overlay" ]]; then
  pass "CALLNOTES_LOCAL_SIGNING=0 leaves ad-hoc (no overlay)"
else
  fail "CALLNOTES_LOCAL_SIGNING=0 overlay path: $out"
fi

wrap_empty="$(mktemp -d)"
cat > "$wrap_empty/security" <<'WRAP'
#!/bin/bash
if [[ "$1" == "find-identity" ]]; then
  exit 0
fi
exec /usr/bin/security "$@"
WRAP
chmod +x "$wrap_empty/security"
out="$(PATH="$wrap_empty:$PATH" "$ROOT/Scripts/sync-local-signing.sh")"
if [[ "$out" == *'leaving ad-hoc'* ]] && [[ ! -f "$overlay" ]]; then
  pass "missing identity is success (ad-hoc fallback)"
else
  fail "missing-identity path: $out"
fi
rm -rf "$wrap_empty"

out="$("$ROOT/Scripts/sync-local-signing.sh")"
if [[ "$out" == *'applying "CallNotes Local Signing"'* ]] \
  && grep -q 'CODE_SIGN_IDENTITY = CallNotes Local Signing' "$overlay" \
  && grep -q 'ENABLE_HARDENED_RUNTIME = NO' "$overlay"; then
  pass "present identity writes overlay (identity + hardened runtime off)"
else
  fail "present-identity overlay: $out overlay=$(cat "$overlay" 2>/dev/null || true)"
fi
assert_real_identity_present

runtime_build_dir="$(mktemp -d "$ROOT/.local-signing-runtime.XXXXXX")"
if (cd "$ROOT" && xcodegen generate >/dev/null) \
  && xcodebuild -project "$ROOT/CallNotes.xcodeproj" -scheme CallNotesMac \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$runtime_build_dir/DerivedData" build >/dev/null; then
  app="$runtime_build_dir/DerivedData/Build/Products/Debug/CallNotes.app"
  binary="$app/Contents/MacOS/CallNotes"
  if [[ -x "$binary" ]]; then
    codesign_details="$(codesign -dvvv "$binary" 2>&1)"
    code_directory="$(printf '%s\n' "$codesign_details" | awk '/^CodeDirectory / { print; exit }')"
    if [[ -n "$code_directory" && "$code_directory" != *runtime* ]]; then
      pass "local-signed binary has no hardened-runtime flag"
    else
      fail "local-signed binary has hardened-runtime flag: $code_directory"
    fi

    shopt -s nullglob
    reports_before=("$REAL_HOME"/Library/Logs/DiagnosticReports/CallNotes*.ips)
    "$binary" >/dev/null 2>&1 &
    runtime_pid=$!
    sleep 5
    if kill -0 "$runtime_pid" 2>/dev/null; then
      pass "local-signed app remains running"
    else
      fail "local-signed app exited before launch check"
    fi
    reports_after=("$REAL_HOME"/Library/Logs/DiagnosticReports/CallNotes*.ips)
    for report in "${reports_after[@]}"; do
      found=0
      for prior_report in "${reports_before[@]}"; do
        if [[ "$report" == "$prior_report" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" == 0 ]]; then
        fail "local-signed app created crash report: $report"
      fi
    done
    if [[ "$failures" == 0 ]]; then
      pass "local-signed app adds no crash report"
    fi
  else
    fail "local-signed app binary missing: $binary"
  fi
else
  fail "could not build local-signed CallNotesMac app"
fi

# --- create_local_signing_identity against a throwaway keychain --------------

bootstrap_create_snippet() {
  awk '
    /^say\(\)/ {print; next}
    /^login_keychain_path\(\)/ {keep=1; fn="login"}
    /^create_local_signing_identity\(\)/ {keep=1; fn="create"}
    keep {print}
    fn=="login" && /^}/ {keep=0; fn=""; next}
    fn=="create" && /^}/ {exit}
  ' "$ROOT/Scripts/bootstrap.sh"
}

make_temp_login_keychain() {
  local tmp_home="$1"
  mkdir -p "$tmp_home/Library/Keychains"
  local keychain="$tmp_home/Library/Keychains/login.keychain-db"
  if [[ "$keychain" == "$REAL_LOGIN" ]]; then
    echo "refusing to use the real login keychain" >&2
    return 2
  fi
  security create-keychain -p 'test-pass' "$keychain" >/dev/null
  pin_user_keychains
  security set-keychain-settings -t 3600 "$keychain" >/dev/null || true
  security unlock-keychain -p 'test-pass' "$keychain" >/dev/null || true
  printf '%s\n' "$keychain"
}

count_cn() {
  local keychain="$1"
  security find-certificate -a -c "CallNotes Local Signing" "$keychain" 2>/dev/null \
    | grep -c '"labl"<blob>="CallNotes Local Signing"' || true
}

# Failed trust (add-trusted-cert returns non-zero) must roll back the import.
fail_wrap="$(mktemp -d)"
cat > "$fail_wrap/security" <<'WRAP'
#!/bin/bash
if [[ "$1" == "add-trusted-cert" ]]; then
  echo "mock: add-trusted-cert failed" >&2
  exit 1
fi
exec /usr/bin/security "$@"
WRAP
chmod +x "$fail_wrap/security"

tmp_home="$(mktemp -d)"
create_log="$(mktemp)"
snippet="$(mktemp)"
bootstrap_create_snippet >"$snippet"
tmp_keychain="$(make_temp_login_keychain "$tmp_home")"
set +e
HOME="$tmp_home" PATH="$fail_wrap:$PATH" bash -c '
  set -euo pipefail
  source "$1/Scripts/sync-local-signing.sh"
  # shellcheck disable=SC1090
  source "$2"
  create_local_signing_identity
' bash "$ROOT" "$snippet" >"$create_log" 2>&1
create_status=$?
set -e
pin_user_keychains
leftover="$(count_cn "$tmp_keychain")"
if [[ "$create_status" -ne 0 && "$leftover" == "0" ]] && grep -q "could not trust" "$create_log"; then
  pass "failed trust rolls back imported identity (leftover=$leftover)"
else
  fail "failed-trust rollback status=$create_status leftover=$leftover log=$(tr '\n' ' ' < "$create_log")"
fi
assert_real_identity_present
security delete-keychain "$tmp_keychain" >/dev/null 2>&1 || true
pin_user_keychains
rm -rf "$tmp_home" "$fail_wrap" "$create_log" "$snippet"

# Interrupt after import (while trust is in progress) must also roll back.
hang_wrap="$(mktemp -d)"
cat > "$hang_wrap/security" <<'WRAP'
#!/bin/bash
if [[ "$1" == "add-trusted-cert" ]]; then
  echo "mock: add-trusted-cert hanging" >&2
  sleep 60
  exit 1
fi
exec /usr/bin/security "$@"
WRAP
chmod +x "$hang_wrap/security"

tmp_home="$(mktemp -d)"
create_log="$(mktemp)"
snippet="$(mktemp)"
bootstrap_create_snippet >"$snippet"
tmp_keychain="$(make_temp_login_keychain "$tmp_home")"
HOME="$tmp_home" PATH="$hang_wrap:$PATH" bash -c '
  set -euo pipefail
  source "$1/Scripts/sync-local-signing.sh"
  # shellcheck disable=SC1090
  source "$2"
  create_local_signing_identity
' bash "$ROOT" "$snippet" >"$create_log" 2>&1 &
create_pid=$!
imported=0
for _ in {1..40}; do
  if [[ "$(count_cn "$tmp_keychain")" != "0" ]]; then
    imported=1
    break
  fi
  if ! kill -0 "$create_pid" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
if [[ "$imported" != 1 ]]; then
  fail "interrupt test never reached import; log=$(tr '\n' ' ' < "$create_log")"
  pkill -TERM -P "$create_pid" 2>/dev/null || true
  kill -TERM "$create_pid" 2>/dev/null || true
  wait "$create_pid" 2>/dev/null || true
else
  pkill -TERM -P "$create_pid" 2>/dev/null || true
  kill -TERM "$create_pid" 2>/dev/null || true
  wait "$create_pid" 2>/dev/null || true
  leftover="$(count_cn "$tmp_keychain")"
  if [[ "$leftover" == "0" ]]; then
    pass "TERM after import rolls back imported identity"
  else
    fail "TERM leftover=$leftover log=$(tr '\n' ' ' < "$create_log")"
  fi
fi
pin_user_keychains
assert_real_identity_present
security delete-keychain "$tmp_keychain" >/dev/null 2>&1 || true
pin_user_keychains
rm -rf "$tmp_home" "$hang_wrap" "$create_log" "$snippet"

if [[ "$failures" -ne 0 ]]; then
  printf '%s failing check(s)\n' "$failures"
  exit 1
fi
printf 'all local-signing identity checks passed\n'
