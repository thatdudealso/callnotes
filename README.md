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
without losing the call. The Mac history also includes a real-time dashboard
for per-call and day/week/month call volume, talk time, Meta costs, engine
usage, and repeat contacts; selecting a period or contact reveals its calls.
Phase 5 adds Mac import paths: an iCloud Drive
`CallNotes/Inbox` watcher (FSEvents, with an Application Support fallback)
imports dropped audio after the file settles, skips duplicates, transcribes
through Apple SpeechAnalyzer, FluidAudio Parakeet, or Meta using the same
9.5-minute / 5-second-overlap chunk-and-stitch path, writes into the dedicated
Postgres store with the same notes spine as live calls, and shows import
progress in the history window. Live Meta file imports stay deferred until
tenant billing is enabled; the simulated harness covers that path in tests.
Phase 6 adds iPhone sync. The Mac serves a TLS API to the local network,
advertises it over Bonjour as `_callnotes._tcp`, and shows a pairing QR code in
Settings → Devices, where a paired iPhone can also be revoked. The iPhone app
scans that code, pins the Mac's certificate, and uploads recordings to it in
the background: a call recording shared into CallNotes from Notes, Voice Memos,
Files, or Mail, or a meeting captured with the app's own in-person recorder.
Uploads resume after a relaunch, a recording the Mac refuses is dropped from
the queue and reported under Settings → Uploads instead of retried forever,
and the phone mirrors the resulting calls, transcripts, and notes so they can
be read without the Mac.

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
Drop a supported audio file (`.m4a`, `.caf`, `.wav`, `.aiff`, `.aif`, or
`.aac`) into the Inbox folder (menu bar → Open Inbox folder) to import a
recording. Phone sync is a Hummingbird server over TLS on the Mac; pairing,
the Mac's TLS identity, and the phone upload types live in the core package's
`Sync` folder. The iPhone app and its Share Extension stage audio in a shared
App Group and upload it with a background `URLSession` pinned to the paired
Mac's certificate, and the phone keeps a SwiftData mirror of the Mac's calls.

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
  -destination 'platform=macOS,arch=arm64' build
xcodebuild -project CallNotes.xcodeproj -scheme CallNotesIOS \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64
```

Local Mac builds sign with the stable identity so macOS permission grants
survive a rebuild. CI keeps `CODE_SIGNING_ALLOWED=NO`; see
[docs/ci.md](docs/ci.md).

The `CallNotesIOS` scheme builds the iPhone app and embeds its Share
Extension. The simulator build is Apple silicon only: FluidAudio vendors
`NemoTextProcessing.xcframework`, whose simulator slice is `ios-arm64-simulator`
with no x86_64 counterpart, so dropping `ARCHS=arm64` fails the Share
Extension link for x86_64. The app and the extension are both entitled to the
App Group they hand recordings to the background uploader through, and to the
keychain group holding the paired Mac's token (both identifiers are listed in
[docs/brand.md](docs/brand.md)), so a signed build needs a provisioning
profile that grants them.

`project.yml` is the source of truth for the Xcode project. Run `xcodegen
generate` whenever it changes; the generated project is deliberately ignored.

For the dedicated local Postgres instance, the local code-signing identity,
and the pinned Ollama notes models, review then run `Scripts/bootstrap.sh`.
Use `Scripts/bootstrap.sh --check` to see the operations without making
changes. The script pull-then-verifies each model digest in
[docs/models.md](docs/models.md). Live notes generation against those models
is gated on `CALLNOTES_OLLAMA=1`.

## Local code signing

macOS stores Microphone and Screen & System Audio Recording grants against an
app's designated requirement. An ad-hoc signature's requirement is the
cdhash, which changes on every rebuild, so those prompts return. Bootstrap
creates a self-signed identity named `CallNotes Local Signing` in the login
keychain (idempotent). `xcodegen generate` then signs `CallNotesMac` and
`CallNotesCaptureHarness` with it so the grants survive rebuilds.

This identity is local-development only. It is not an Apple Developer
certificate and cannot notarize or distribute. CI and any clone without the
certificate keep the previous ad-hoc behavior. Set
`CALLNOTES_LOCAL_SIGNING=0` before `xcodegen generate` to force that fallback
on a machine that has the identity.

## License and attribution

CallNotes is released under the [MIT License](LICENSE). It selectively vendors
adapted components from Megaphone under its MIT license; the component-level
decisions and full notice are in [THIRD_PARTY.md](THIRD_PARTY.md).
