#!/usr/bin/env bash
# Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone), MIT License:
#   Copyright (c) 2026 Kuber Mehta (Megaphone)
#   Copyright (c) 2026 Zach Latta (FreeFlow)
# See THIRD_PARTY.md. Adapted for CallNotes: rewritten from the upstream
# Makefile's app-bundle/dmg/codesign-dmg targets into a standalone script;
# builds with xcodegen + xcodebuild (scheme CallNotesMac, tool target
# CallNotesLauncher) instead of raw swiftc; renamed the app, bundle id, and
# the core-executable Info.plist key; made the volume icon, DMG background,
# and entitlements optional; moved notarization out to notarize.sh.
#
# Assembles CallNotes.app with the launcher-as-main-executable arrangement:
# the CallNotesLauncher binary ships as Contents/MacOS/CallNotes (the
# CFBundleExecutable), the real app binary ships alongside it as
# Contents/MacOS/CallNotesCore, and the Info.plist key CallNotesCoreExecutable
# names the core binary so the launcher can exec it on macOS 26+ (older
# systems get a clear "requires macOS 26" alert instead of Launch Services
# error -10825). The script then codesigns inside-out with the Developer ID
# identity, packages a drag-to-Applications DMG, and signs the DMG.
#
# Required environment:
#   CODESIGN_IDENTITY  Developer ID Application identity name, or "-" for
#                      an explicit ad-hoc signature (local testing only).
# Optional environment:
#   ARCH          arm64 | x86_64 | universal (default: host architecture)
#   VERSION       stamps CFBundleShortVersionString after assembly
#   BUILD_NUMBER  stamps CFBundleVersion after assembly
#   BUILD_TAG     stamps CallNotesBuildTag after assembly
#   ENTITLEMENTS  entitlements plist for codesign
#                 (default: CallNotesMac/Resources/CallNotes.entitlements,
#                 used only if the file exists)

set -euo pipefail

APP_NAME="CallNotes"
CORE_NAME="CallNotesCore"
LAUNCHER_TARGET="CallNotesLauncher"
SCHEME="CallNotesMac"
PROJECT="CallNotes.xcodeproj"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
ICON_ICNS="CallNotesMac/Resources/AppIcon.icns"
DMG_BACKGROUND="CallNotesMac/Resources/dmg-background.tiff"
ENTITLEMENTS="${ENTITLEMENTS:-CallNotesMac/Resources/CallNotes.entitlements}"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_env() {
  local name="$1" hint="$2"
  if [[ -z "${!name:-}" ]]; then
    fail "required environment variable $name is not set. $hint"
  fi
}

require_tool() {
  local tool="$1" hint="$2"
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "required tool '$tool' not found. $hint"
  fi
}

require_env CODESIGN_IDENTITY \
  'Set it to your "Developer ID Application: ..." identity, or "-" for an explicit ad-hoc signature.'
require_tool xcodegen "Install with: brew install xcodegen"
require_tool xcodebuild "Install Xcode and its command line tools."
require_tool create-dmg "Install with: brew install create-dmg"
require_tool fileicon "Install with: brew install fileicon"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64 | x86_64) ARCHS="$ARCH" ;;
  universal) ARCHS="arm64 x86_64" ;;
  *) fail "ARCH must be arm64, x86_64, or universal (got: $ARCH)" ;;
esac

echo "Building $APP_NAME ($ARCH) with identity: $CODESIGN_IDENTITY"

# --- Generate the Xcode project (CallNotes.xcodeproj is not committed) ---
xcodegen generate

# --- Build the core app and the compatibility launcher ---
# Codesigning is disabled during the build; the assembled bundle is signed
# manually below, inside-out, exactly once.
DERIVED_DATA="$BUILD_DIR/DerivedData"
LAUNCHER_SYMROOT="$BUILD_DIR/launcher-symroot"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

# The launcher is a dependency-free tool target, so a plain target build is
# enough; SYMROOT pins the product location.
xcodebuild \
  -project "$PROJECT" \
  -target "$LAUNCHER_TARGET" \
  -configuration Release \
  SYMROOT="$LAUNCHER_SYMROOT" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PRODUCT="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
LAUNCHER_PRODUCT="$LAUNCHER_SYMROOT/Release/$LAUNCHER_TARGET"
[[ -d "$APP_PRODUCT" ]] || fail "expected app product at $APP_PRODUCT"
[[ -f "$LAUNCHER_PRODUCT" ]] || fail "expected launcher product at $LAUNCHER_PRODUCT"

# --- Assemble the release bundle ---
# The bundle's main executable becomes the launcher, which deploys back to
# macOS 13. Older systems can actually run it and get told that macOS 26 is
# required, instead of Launch Services failing with error -10825; on
# macOS 26+ it execs the core binary named by CallNotesCoreExecutable.
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"
cp -R "$APP_PRODUCT" "$APP_BUNDLE"

MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
mv "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$CORE_NAME"
cp "$LAUNCHER_PRODUCT" "$MACOS_DIR/$APP_NAME"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -replace CallNotesCoreExecutable -string "$CORE_NAME" "$INFO_PLIST"

if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"
fi
if [[ -n "${BUILD_TAG:-}" ]]; then
  plutil -replace CallNotesBuildTag -string "$BUILD_TAG" "$INFO_PLIST"
fi

# --- Codesign inside-out: core binary first, then the bundle ---
# Signing the bundle signs its main executable (the launcher).
codesign_args=(--force --options runtime --sign "$CODESIGN_IDENTITY")
if [[ -f "$ENTITLEMENTS" ]]; then
  codesign_args+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${codesign_args[@]}" "$MACOS_DIR/$CORE_NAME"
codesign "${codesign_args[@]}" "$APP_BUNDLE"
echo "Built and signed $APP_BUNDLE"

# --- Create the drag-to-Applications DMG ---
rm -f "$DMG_PATH"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"

STAGING_ABS="$(cd "$STAGING" && pwd)"
osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$STAGING_ABS"'"'
ALIAS="$(find "$STAGING" -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1)"
[[ -n "$ALIAS" ]] || fail "could not find the Applications alias in $STAGING"
mv "$ALIAS" "$STAGING/Applications"
fileicon set "$STAGING/Applications" \
  /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns

echo "Creating DMG..."
dmg_args=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 660 400
  --icon-size 128
  --icon "$APP_NAME.app" 180 170
  --hide-extension "$APP_NAME.app"
  --icon "Applications" 480 170
  --no-internet-enable
)
if [[ -f "$ICON_ICNS" ]]; then
  dmg_args+=(--volicon "$ICON_ICNS")
fi
if [[ -f "$DMG_BACKGROUND" ]]; then
  dmg_args+=(--background "$DMG_BACKGROUND")
fi
create-dmg "${dmg_args[@]}" "$DMG_PATH" "$STAGING"
rm -rf "$STAGING"

# --- Sign the DMG itself ---
codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
echo "Created and signed $DMG_PATH"
echo "Next: Scripts/release/notarize.sh to notarize and staple it."
