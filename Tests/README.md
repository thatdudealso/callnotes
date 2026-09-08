# Tests

Cross-target test harnesses land here as the phases that need them arrive
(plan section 16):

- capture test harness (Phase 1) - `Tests/CaptureHarness` plus
  `Scripts/run-capture-harness.sh`. Plays a synthetic click+tone through the
  default output (stand-in for a live call) from the separate
  `Tests/CaptureHarnessPlayback` helper process - the global tap excludes the
  harness's own process, so in-process playback would be silent - and asserts
  both CAF channels are non-silent and aligned within 50 ms from their capture
  host timestamps.
- golden-file provider tests and the diarization/identity accuracy harness
  (Phase 2),
- Meta provider integration tests (Phase 4),
- live Ollama notes generation for both pinned models (`CALLNOTES_OLLAMA=1`),
- backup/restore and failure-injection scenarios (Phase 7).

Unit tests for pure logic live inside the package:
`Packages/CallNotesCore/Tests/CallNotesCoreTests` (run with
`swift test --package-path Packages/CallNotesCore`).
