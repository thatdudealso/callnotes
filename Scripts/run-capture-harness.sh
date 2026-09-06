#!/usr/bin/env bash
# Phase 1 capture harness (plan section 16.3).
# Plays a synthetic click+tone through the default output and records
# system audio + microphone into a 2-channel CAF, then asserts both
# channels are non-silent and aligned within 50 ms.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

derived="${CALLNOTES_DERIVED_DATA:-$root/.build/CaptureHarnessDerivedData}"
xcodebuild \
  -project CallNotes.xcodeproj \
  -scheme CallNotesCaptureHarness \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  build \
  CODE_SIGNING_ALLOWED=YES

product="$(find "$derived/Build/Products" -name CallNotesCaptureHarness -type f | head -1)"
if [[ -z "$product" ]]; then
  echo "Could not find CallNotesCaptureHarness product under $derived" >&2
  exit 1
fi

echo "Running $product"
exec "$product"
