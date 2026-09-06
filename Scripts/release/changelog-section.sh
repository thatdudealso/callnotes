#!/usr/bin/env bash
# Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone), MIT License:
#   Copyright (c) 2026 Kuber Mehta (Megaphone)
#   Copyright (c) 2026 Zach Latta (FreeFlow)
# See THIRD_PARTY.md. Adapted for CallNotes: verbatim apart from this
# attribution header; extracts one version's section from CHANGELOG.md
# for use as release notes.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

version="$1"
changelog="CHANGELOG.md"

if [[ ! -f "$changelog" ]]; then
  echo "Missing $changelog" >&2
  exit 1
fi

awk -v version="$version" '
  BEGIN {
    in_section = 0
    found = 0
  }

  /^## / {
    if (in_section) {
      exit
    }

    if ($0 ~ "^## \\[" version "\\]([[:space:]-]|$)") {
      in_section = 1
      found = 1
      print
      next
    }
  }

  in_section {
    print
  }

  END {
    if (!found) {
      print "No changelog section found for version " version > "/dev/stderr"
      exit 1
    }
  }
' "$changelog"
