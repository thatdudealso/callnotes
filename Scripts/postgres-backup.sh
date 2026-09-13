#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec swift run --package-path "$SCRIPT_DIR/../Packages/CallNotesCore" CallNotesBackup "$@"
