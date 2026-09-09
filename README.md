# CallNotes

CallNotes is a local-first call transcription and speaker-labeled notes app for
Mac and iPhone. It targets macOS 26 and iOS 26, with the Mac acting as the
private processing and storage hub.

## Status

CallNotes is in early development. Phase 1 adds Mac call detection and local,
two-channel capture. Phase 2 provides a thin local proof path: a synthetic
two-channel sample call is transcribed with Apple SpeechAnalyzer, diarized and
speaker-labeled with FluidAudio, then stored in the dedicated local Postgres
database for the Mac history and detail views. Phase 3 adds instant hang-up
title/tl;dr via Apple Foundation Models and deep structured notes via local
Ollama (Muse Glimmer 30B, with a Qwen3 Instruct fallback). Phase 4 adds an
optional Meta Muse cloud transcription engine: local transcription stays the
default, the default engine is chosen in Settings (Engines) or onboarding,
each call can override it or be re-transcribed with Meta, billed Meta seconds
are tracked per call, and any Meta failure falls back to local transcription
without losing the call. Phase 5 adds Mac import paths: an iCloud Drive
`CallNotes/Inbox` watcher (FSEvents, with an Application Support fallback)
imports dropped audio after the file settles, skips duplicates, transcribes
through Apple SpeechAnalyzer, FluidAudio Parakeet, or Meta using the same
9.5-minute / 5-second-overlap chunk-and-stitch path, writes into the dedicated
Postgres store with the same notes spine as live calls, and shows import
progress in the history window. Live Meta file imports stay deferred until
tenant billing is enabled; the simulated harness covers that path in tests.
Phone sync remains later-phase work.

Some docs and code comments cite "plan section" numbers. These refer to the
private implementation plan that maintainers keep locally at
`docs/private/callnotes-implementation-plan.md`; `docs/private/` is gitignored
and is never part of the public repository.

## Architecture

The Mac app processes the bundled sample call locally, with shared Swift domain
models and provider protocols in `Packages/CallNotesCore`. The core package
uses Apple SpeechAnalyzer and FluidAudio locally, Postgres for the Mac-side
store, Apple Foundation Models for instant notes, and Ollama for deep notes.
The optional Meta Muse cloud transcription engine sits behind the same
provider seams, with the API key kept in the Keychain and local providers as
the automatic fallback.
Drop an m4a into the Inbox folder (menu bar → Open Inbox folder) to import a
recording. Hummingbird remains planned for the phone-sync phase. The iPhone app
and Share Extension are intentionally minimal Phase 0 shells that will later
upload recordings to the paired Mac.

## Capture harness

To verify capture hardware with a synthetic far-end signal, run
`Scripts/run-capture-harness.sh`. It requires Microphone access and, for system
audio, System Settings → Privacy & Security → Screen & System Audio Recording
→ System Audio Recording Only. See [Tests/README.md](Tests/README.md) for the
harness contract and its output.

## Build

Prerequisites: Xcode 26 or newer with macOS 26/iOS 26 SDKs, Swift 6.2, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift build --package-path Packages/CallNotesCore
swift test --package-path Packages/CallNotesCore
xcodegen generate
xcodebuild -project CallNotes.xcodeproj -scheme CallNotesMac \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

`project.yml` is the source of truth for the Xcode project. Run `xcodegen
generate` whenever it changes; the generated project is deliberately ignored.

For the dedicated local Postgres instance and the pinned Ollama notes models,
review then run `Scripts/bootstrap.sh`. Use `Scripts/bootstrap.sh --check` to
see the operations without making changes. The script pull-then-verifies each
model digest in [docs/models.md](docs/models.md). Live notes generation against
those models is gated on `CALLNOTES_OLLAMA=1`.

## License and attribution

CallNotes is released under the [MIT License](LICENSE). It selectively vendors
adapted components from Megaphone under its MIT license; the component-level
decisions and full notice are in [THIRD_PARTY.md](THIRD_PARTY.md).
