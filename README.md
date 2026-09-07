# CallNotes

CallNotes is a local-first call transcription and speaker-labeled notes app for
Mac and iPhone. It targets macOS 26 and iOS 26, with the Mac acting as the
private processing and storage hub.

## Status

CallNotes is in early development. Phase 1 adds Mac call detection and local,
two-channel capture. Phase 2 provides a thin local proof path: a synthetic
two-channel sample call is transcribed with Apple SpeechAnalyzer, diarized and
speaker-labeled with FluidAudio, then stored in the dedicated local Postgres
database for the Mac history and detail views. Notes and phone sync remain
later-phase work.

Some docs and code comments cite "plan section" numbers. These refer to the
private implementation plan that maintainers keep locally at
`docs/private/callnotes-implementation-plan.md`; `docs/private/` is gitignored
and is never part of the public repository.

## Architecture

The Mac app processes the bundled sample call locally, with shared Swift domain
models and provider protocols in `Packages/CallNotesCore`. The core package
uses Apple SpeechAnalyzer and FluidAudio locally and Postgres for the Mac-side
store; Hummingbird and Ollama support are planned for later phases. The iPhone
app and Share Extension are intentionally minimal Phase 0 shells that will
later upload recordings to the paired Mac.

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

For the dedicated local Postgres instance, review then run
`Scripts/bootstrap.sh`. Use `Scripts/bootstrap.sh --check` to see the
operations without making changes. Ollama and the pinned notes models are not
downloaded in this phase; see [docs/models.md](docs/models.md) for the
immutable model references that the notes phase will install.

## License and attribution

CallNotes is released under the [MIT License](LICENSE). It selectively vendors
adapted components from Megaphone under its MIT license; the component-level
decisions and full notice are in [THIRD_PARTY.md](THIRD_PARTY.md).
