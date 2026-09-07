#!/usr/bin/env bash
# Generate a small synthetic 2-channel CAF for the Phase 2 spine and DER harness.
# Uses macOS `say` so the near/far channels contain speech, not copyrighted audio.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift "$ROOT/Scripts/GenerateDiarizationFixture.swift"
