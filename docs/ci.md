# CI

Workflow: `.github/workflows/ci.yml`, running on every push to `main` and every pull request.

## Jobs

- **CallNotesCore build + test** - `swift build` and `swift test` for `Packages/CallNotesCore` on a `macos-26` hosted runner.
- **CallNotesMac app build** - regenerates the Xcode project with XcodeGen (`xcodegen generate`) and builds the `CallNotesMac` scheme with code signing disabled.
- **Shell + workflow lint** - shellcheck over `Scripts/**/*.sh` and actionlint over the workflows, on Ubuntu (cheap and fast).

## Runner / SDK notes

- GitHub's hosted `macos-26` (Apple silicon) image is available and ships Xcode 26.x, which is required: CallNotesCore compiles against SpeechAnalyzer and FoundationModels APIs that only exist in the macOS 26 / iOS 26 SDKs. The "Select newest Xcode 26" step pins the newest Xcode 26 on the image so a default-Xcode bump to a future major does not silently change the SDK.
- Unit tests in CI are hardware-independent by design (merge/normalize logic, threshold math, schema validation, engine-default resolution, dictionary/tidier logic). Anything needing real audio hardware, the ANE, Postgres, or Ollama runs locally via the harnesses planned under `Tests/` (see plan phases), not in hosted CI.
- iOS targets are not built in CI yet; they are Phase 0 stubs. An iOS Simulator build job can be added once the targets carry real code.

## Local equivalent

```bash
swift build --package-path Packages/CallNotesCore
swift test --package-path Packages/CallNotesCore
xcodegen generate
xcodebuild -project CallNotes.xcodeproj -scheme CallNotesMac -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
shellcheck Scripts/**/*.sh
actionlint
```
