# Pinned local models

This file is the source of truth for the pinned notes-model references. The
notes phase will pull the named model tags and verify each local manifest
digest against the expected value; Phase 2's `Scripts/bootstrap.sh` does not
download any Ollama models.

| Purpose | Model reference | Manifest digest | Why it is present |
| --- | --- | --- | --- |
| Default deep notes | `muse-glimmer:30b` | `sha256:de878ce33ad81d060001db1469a02eebe4d86f0ad58cfe52dc062fdcbe4464c1` | Official Muse Glimmer 30B Q4_K_M build, about 18 GB. |
| Fallback deep notes | `qwen3:30b-instruct` | `sha256:19e422b0231392335cfc49cfd172de7034bb1aeabb08aa307cce745c60b272fe` | Proven 30.5B Qwen3 Instruct Q4_K_M build, about 19 GB. |

The manifest digests were resolved from the Ollama registry on 2026-09-06.
The fallback is Qwen3 30B Instruct because it is an established instruction
model in the requested 27-32B range. Health checks in later phases will verify
both pinned references before reporting deep-note generation as ready.
