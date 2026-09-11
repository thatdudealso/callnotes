# CI

Workflow: `.github/workflows/ci.yml`, running on every push to `main` and every pull request.

## Jobs

- **CallNotesCore build + test** - `swift build` and `swift test` for `Packages/CallNotesCore` on a `macos-26` hosted runner.
- **CallNotesMac app build** - regenerates the Xcode project with XcodeGen (`xcodegen generate`) and builds the `CallNotesMac` scheme with code signing disabled.
- **Shell + workflow lint** - shellcheck over `Scripts/**/*.sh` and actionlint over the workflows, on Ubuntu (cheap and fast).

## Runner / SDK notes

- GitHub's hosted `macos-26` (Apple silicon) image is available and ships Xcode 26.x, which is required: CallNotesCore compiles against SpeechAnalyzer and FoundationModels APIs that only exist in the macOS 26 / iOS 26 SDKs. The "Select newest Xcode 26" step pins the newest Xcode 26 on the image so a default-Xcode bump to a future major does not silently change the SDK.
- Unit tests in CI are hardware-independent by design (merge/normalize logic, threshold math, schema validation, engine-default resolution, dictionary/tidier logic, notes schema/map-reduce/fallback). Anything needing real audio hardware, the ANE, Postgres, Ollama, or the billed Meta API runs locally via the opt-in gates (`CALLNOTES_HARNESS=1`, `CALLNOTES_OLLAMA=1`, `CALLNOTES_META=1`), not in hosted CI.
- iOS targets are not built in CI yet, although the Phase 6 app and Share Extension now carry real code. An iOS Simulator build job (`-scheme CallNotesIOS -destination 'generic/platform=iOS Simulator' ARCHS=arm64`, code signing disabled, Apple silicon only because FluidAudio ships no x86_64 simulator slice) still needs to be added; until then the phone targets are only built locally, and the Phase 6 sync logic that CI does cover is the part that lives in `CallNotesCore` (pairing, the upload inbox, mirror reconciliation).

## Local equivalent

```bash
swift build --package-path Packages/CallNotesCore
swift test --package-path Packages/CallNotesCore
xcodegen generate
xcodebuild -project CallNotes.xcodeproj -scheme CallNotesMac -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
shellcheck Scripts/**/*.sh
actionlint
```
