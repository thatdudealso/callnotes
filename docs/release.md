# Release pipeline

CallNotes ships as a signed, notarized DMG. The pipeline is vendored from
Megaphone (https://github.com/Kuberwastaken/megaphone, MIT) and adapted to
this repo; see THIRD_PARTY.md for attribution. It lives in `Scripts/release/`:

| Script | What it does |
| --- | --- |
| `build-dmg.sh` | Generates `CallNotes.xcodeproj` (`xcodegen generate`), builds the app (scheme `CallNotesMac`) and the compatibility launcher (tool target `CallNotesLauncher`), assembles `build/CallNotes.app`, codesigns it with the Developer ID identity, packages a drag-to-Applications `build/CallNotes.dmg`, and signs the DMG. |
| `notarize.sh` | Submits the signed DMG to Apple's notary service (`notarytool submit --wait`) and staples the ticket (`stapler staple`). |
| `changelog-section.sh` | Prints one version's section from `CHANGELOG.md`, used as the GitHub release notes body. |

A typical release build is:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
ARCH=universal VERSION=0.1.0 BUILD_NUMBER=1 BUILD_TAG=v0.1.0 \
  Scripts/release/build-dmg.sh

NOTARIZE_PROFILE=notarytool-profile Scripts/release/notarize.sh
```

## The launcher / core executable arrangement

The real app binary is compiled against the macOS 26 SDK. On older systems,
Launch Services refuses to start such a binary with the opaque error -10825
instead of saying why. To fix that, the release bundle is arranged so that:

- `Contents/MacOS/CallNotes` - the bundle's main executable
  (`CFBundleExecutable`) - is the small `CallNotesLauncher` binary, which
  deploys back to macOS 13 so old systems can actually run it.
- `Contents/MacOS/CallNotesCore` is the real app binary, renamed from the
  Xcode build product.
- The Info.plist key `CallNotesCoreExecutable` names the core binary
  (`CallNotesCore`).

On macOS 26+ the launcher looks up `CallNotesCoreExecutable`, finds the core
binary next to itself, and replaces itself with it via `execv`. On anything
older it shows an alert explaining the macOS 26 requirement and offers to open
Software Update. `build-dmg.sh` performs this rearrangement; debug builds from
Xcode run the core binary directly and skip the launcher.

Codesigning is done inside-out: the core binary is signed first, then the
bundle (which signs the launcher as the main executable), then the DMG. All
signatures use `--options runtime` (hardened runtime), which notarization
requires.

## Required environment / secrets

`build-dmg.sh`:

- `CODESIGN_IDENTITY` (required) - the "Developer ID Application: ..."
  identity name, or `-` for an explicit ad-hoc signature (local testing only;
  ad-hoc builds cannot be notarized).
- `ARCH` (optional) - `arm64`, `x86_64`, or `universal`; defaults to the host
  architecture.
- `VERSION`, `BUILD_NUMBER`, `BUILD_TAG` (optional) - stamped into the
  assembled bundle's Info.plist (`CFBundleShortVersionString`,
  `CFBundleVersion`, `CallNotesBuildTag`).
- `ENTITLEMENTS` (optional) - entitlements plist for codesign; defaults to
  `CallNotesMac/Resources/CallNotes.entitlements` when that file exists.

Tools: Xcode (macOS 26 SDK), plus `brew install xcodegen create-dmg fileicon`.

`notarize.sh`:

- `NOTARIZE_PROFILE` (required) - a `notarytool` keychain profile, created
  once with
  `xcrun notarytool store-credentials <profile> --apple-id ... --team-id ... --password ...`
  (the password is an app-specific password, not the Apple ID password).
- `KEYCHAIN_PATH` (optional) - keychain holding that profile; used in CI
  where credentials live in a temporary keychain.

When the GitHub Actions release workflow is added, it will need these repo
secrets (same names the vendored upstream workflow uses):

- `DEVELOPER_ID_CERTIFICATE_BASE64` - base64-encoded `.p12` Developer ID
  Application certificate.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD` - password for the `.p12`.
- `APPLE_ID` - Apple ID email for notarization.
- `APPLE_TEAM_ID` - 10-character Apple Team ID.
- `APPLE_APP_PASSWORD` - app-specific password for notarization.

## GitHub Actions workflow

There is intentionally no release workflow yet. When CallNotes first ships,
a tag-triggered workflow (`v*.*.*` on `thatdudealso/callnotes`) will be added
that imports the certificate into a temporary keychain, stores the notarytool
profile, runs `build-dmg.sh` and `notarize.sh`, builds release notes with
`changelog-section.sh`, and uploads `CallNotes.dmg` to the GitHub release.
