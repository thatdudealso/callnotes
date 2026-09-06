# CallNotes

CallNotes is a local-first call transcription and speaker-labeled notes app for
Mac and iPhone. It targets macOS 26 and iOS 26, with the Mac acting as the
private processing and storage hub.

## Status

CallNotes is in early development. Phase 0 establishes the repository,
platform targets, local service bootstrap, and shared domain package. Recording,
transcription, speaker identity, notes, and phone sync are planned in later
phases and are not yet product features.

Some docs and code comments cite "plan section" numbers. These refer to the
private implementation plan that maintainers keep locally at
`docs/private/callnotes-implementation-plan.md`; `docs/private/` is gitignored
and is never part of the public repository.

## Architecture

The Mac app will capture and process calls locally, with shared Swift domain
models and provider protocols in `Packages/CallNotesCore`. The core package is
designed to support Apple SpeechAnalyzer and FluidAudio locally, Postgres for
the Mac-side store, Hummingbird for a local API, and Ollama for deep notes. The
iPhone app and Share Extension are intentionally minimal Phase 0 shells that
will later upload recordings to the paired Mac.

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

For local Postgres, Ollama, Tailscale, and the pinned notes models, review then
run `Scripts/bootstrap.sh`. Use `Scripts/bootstrap.sh --check` to see the
operations without making changes. See [docs/models.md](docs/models.md) for the
immutable model references.

## License and attribution

CallNotes is released under the [MIT License](LICENSE). It selectively vendors
adapted components from Megaphone under its MIT license; the component-level
decisions and full notice are in [THIRD_PARTY.md](THIRD_PARTY.md).
