#!/usr/bin/env bash
# Build the Ivrix Hebrew/BIDI app from this fork.
#
# Pipeline: place the fork-CI-built universal GhosttyKit.xcframework, build the
# cmux Release app locally (zig builds neutralized — GhosttyKit comes from CI,
# CLI helper stubbed), then post-rename cmux -> Ivrix, bundle the Hebrew/Latin
# fonts, ad-hoc sign with minimal entitlements, and zip to the Desktop.
#
# Prereqs:
#   - ghostty/macos/GhosttyKit.xcframework already extracted from the fork CI
#     artifact (the caller does this; see build-ivrix download step).
#   - /tmp/ivrix.entitlements present (minimal ad-hoc entitlements).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DERIVED="/tmp/cmux-ivrix-build"
ENTITLEMENTS="/tmp/ivrix.entitlements"
OUT_APP_PARENT="/tmp/ivrix-stage"
DESKTOP="$HOME/Desktop"

test -d "ghostty/macos/GhosttyKit.xcframework" || {
  echo "ERROR: ghostty/macos/GhosttyKit.xcframework missing (extract CI artifact first)" >&2; exit 1; }
test -f "$ENTITLEMENTS" || { echo "ERROR: $ENTITLEMENTS missing" >&2; exit 1; }

echo "==> [1/6] Building cmux Release (universal, GhosttyKit from CI, zig stubbed)"
rm -rf "$DERIVED"
CMUX_GHOSTTYKIT_LOCAL=1 CMUX_SKIP_ZIG_BUILD=1 \
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CMUX_GHOSTTYKIT_LOCAL=1 CMUX_SKIP_ZIG_BUILD=1 \
  build

SRC_APP="$DERIVED/Build/Products/Release/cmux.app"
test -d "$SRC_APP" || { echo "ERROR: build produced no $SRC_APP" >&2; exit 1; }

echo "==> [2/6] Staging + renaming bundle -> Ivrix"
rm -rf "$OUT_APP_PARENT"; mkdir -p "$OUT_APP_PARENT"
APP="$OUT_APP_PARENT/Ivrix.app"
cp -R "$SRC_APP" "$APP"
mv "$APP/Contents/MacOS/cmux" "$APP/Contents/MacOS/Ivrix"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ivrix" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ivrix" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ivrix" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ivrix.app" "$PLIST"

echo "==> [3/6] Bundling fonts into Resources/Fonts"
mkdir -p "$APP/Contents/Resources/Fonts"
cp -f Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

echo "==> [4/6] Ad-hoc signing (minimal entitlements, deep)"
# Plain ad-hoc (no hardened runtime — not notarizing; avoids launch friction).
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"

echo "==> [5/6] Verifying signature + arch"
codesign --verify --deep --verbose=2 "$APP" 2>&1 | tail -3 || true
lipo -archs "$APP/Contents/MacOS/Ivrix" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST"

echo "==> [6/6] Zipping -> $DESKTOP/Ivrix.zip"
rm -f "$DESKTOP/Ivrix.zip"
ditto -c -k --keepParent "$APP" "$DESKTOP/Ivrix.zip"
ls -lh "$DESKTOP/Ivrix.zip"
echo "DONE: $DESKTOP/Ivrix.zip"
