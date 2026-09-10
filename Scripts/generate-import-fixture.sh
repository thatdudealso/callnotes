#!/usr/bin/env bash
# Generate a short synthetic m4a for Phase 5 inbox-import tests.
# Uses macOS `say` so the file contains speech, not a personal recording.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Fixtures/import"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/inbox-hello.m4a"

say -o "$OUT" "Hello Priya. We will ship the pilot next week."
echo "wrote $OUT"
