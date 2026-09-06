# Tests

Cross-target test harnesses land here as the phases that need them arrive
(plan section 16):

- capture test harness (Phase 1) - plays a known recording through a real
  call app and asserts both channels arrive aligned,
- golden-file provider tests and the diarization/identity accuracy harness
  (Phase 2),
- Meta provider integration tests (Phase 4),
- backup/restore and failure-injection scenarios (Phase 7).

Unit tests for pure logic live inside the package:
`Packages/CallNotesCore/Tests/CallNotesCoreTests` (run with
`swift test --package-path Packages/CallNotesCore`).
