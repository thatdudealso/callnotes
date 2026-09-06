# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- `project.yml` is the XcodeGen source of truth. Use the build commands in `README.md`; generated `CallNotes.xcodeproj` is ignored.
- `Scripts/bootstrap.sh` owns local service provisioning and immutable Ollama model references. Use `Scripts/bootstrap.sh --check` before making machine-level changes.
- Phase 2 store: the captain superseded the original `postgresql@16` requirement with dedicated `postgresql@18`. `PostgresStore` targets the bootstrap `callnotes` DB (role `callnotes`, extensions `vector` + `pg_trgm`), with `MemoryStore` fallback when the dedicated Postgres instance is unreachable (CI). `StoreConfiguration.localCandidates()` uses only the dedicated socket and never `/tmp/.s.PGSQL.5432` or port 5432.
- Hardware SpeechAnalyzer and FluidAudio tests are gated on `CALLNOTES_HARNESS=1`. Live Postgres tests run when a candidate socket/server accepts the `callnotes` role.
- Dual SpeechAnalyzer instances must be held alive together in `DualInstanceProbe`; sequential start-and-stop cannot observe ANE contention. Fallback is `nearLiveFarBatch`.
- CAF writes fill a non-interleaved Float32 `AVAudioPCMBuffer`; AVAudioFile may store interleaved CAF. Filling an interleaved buffer or writing Int16 stereo CAF fails (`-50` / ExtAudioFile abort).
- Synthetic diarization audio: `Scripts/generate-diarization-fixture.sh` (macOS `say`, never personal recordings). DER initial target is `DiarizationErrorRate.initialTarget` (0.177).

## Mac capture (Phase 1)

- Shared audio math lives in `Packages/CallNotesCore/Sources/CallNotesCore/Audio`. Mac hardware (process tap, mic, detector, coordinator) lives in `CallNotesMac/Sources/Capture`.
- FaceTime/Phone bundle IDs are observed from display names (`CallAppNameMatcher`) and stored in UserDefaults (`CallAppIdentityStore`); never hardcode them.
- Process tap: `kAudioAggregateDeviceTapAutoStartKey` must be `false` or `AudioDeviceStart` waits forever until the tapped process produces audio. Pass a non-nil queue to `AudioDeviceCreateIOProcIDWithBlock` (nil silently fails on macOS 26).
- TCC: Microphone plus Screen & System Audio Recording → System Audio Recording Only. The CLI harness (`Scripts/run-capture-harness.sh`) must not call `AVCaptureDevice.requestAccess` (no GUI dialog; hangs a headless process).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
