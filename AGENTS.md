# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- `project.yml` is the XcodeGen source of truth. Use the build commands in `README.md`; generated `CallNotes.xcodeproj` is ignored.
- `Scripts/bootstrap.sh` owns local service provisioning and immutable Ollama model references. Use `Scripts/bootstrap.sh --check` before making machine-level changes.

## Mac capture (Phase 1)

- Shared audio math lives in `Packages/CallNotesCore/Sources/CallNotesCore/Audio`. Mac hardware (process tap, mic, detector, coordinator) lives in `CallNotesMac/Sources/Capture`.
- FaceTime/Phone bundle IDs are observed from display names (`CallAppNameMatcher`) and stored in UserDefaults (`CallAppIdentityStore`); never hardcode them.
- Process tap: `kAudioAggregateDeviceTapAutoStartKey` must be `false` or `AudioDeviceStart` waits forever until the tapped process produces audio. Pass a non-nil queue to `AudioDeviceCreateIOProcIDWithBlock` (nil silently fails on macOS 26).
- TCC: Microphone plus Screen & System Audio Recording → System Audio Recording Only. The CLI harness (`Scripts/run-capture-harness.sh`) must not call `AVCaptureDevice.requestAccess` (no GUI dialog; hangs a headless process).
- Live FaceTime / macOS Phone acceptance is captain-run; the harness uses synthetic playback as a stand-in.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
