#!/usr/bin/env bash
# Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone), MIT License:
#   Copyright (c) 2026 Kuber Mehta (Megaphone)
#   Copyright (c) 2026 Zach Latta (FreeFlow)
# See THIRD_PARTY.md. Adapted for CallNotes: extracted from the upstream
# Makefile's notarize target into a standalone script; renamed the DMG,
# added env-var validation and optional --keychain support for CI's
# temporary keychain.
#
# Submits the signed DMG to Apple's notary service, waits for the verdict,
# and staples the notarization ticket to the DMG on success.
#
# Usage: Scripts/release/notarize.sh [path/to/CallNotes.dmg]
#   (default: build/CallNotes.dmg)
#
# Required environment:
#   NOTARIZE_PROFILE  notarytool keychain profile name, created with:
#                     xcrun notarytool store-credentials <profile> \
#                       --apple-id ... --team-id ... --password ...
# Optional environment:
#   KEYCHAIN_PATH     keychain holding the profile (CI's temporary keychain)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DMG_PATH="${1:-build/CallNotes.dmg}"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ -z "${NOTARIZE_PROFILE:-}" ]]; then
  fail "required environment variable NOTARIZE_PROFILE is not set. Create a profile with 'xcrun notarytool store-credentials' and pass its name."
fi
[[ -f "$DMG_PATH" ]] || fail "DMG not found at $DMG_PATH. Run Scripts/release/build-dmg.sh first."

submit_args=(--keychain-profile "$NOTARIZE_PROFILE")
if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
  submit_args+=(--keychain "$KEYCHAIN_PATH")
fi

xcrun notarytool submit "$DMG_PATH" "${submit_args[@]}" --wait
xcrun stapler staple "$DMG_PATH"
echo "Notarized and stapled $DMG_PATH"
