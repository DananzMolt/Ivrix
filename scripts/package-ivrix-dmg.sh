#!/usr/bin/env bash
# Package the locally built Ivrix.app into a notarized, stapled DMG.
#
# Unlike scripts/notarize-ivrix.sh (which pulls the ad-hoc zip from a GitHub
# release), this works on the app this checkout just built, so you can ship a
# DMG straight from a branch.
#
# Pipeline:
#   1. Re-sign the staged app with Developer ID + hardened runtime, inside-out.
#   2. Notarize the app and staple its ticket.
#   3. Build a DMG with an /Applications drop target.
#   4. Sign, notarize and staple the DMG itself.
#
# Both the app and the DMG are notarized: stapling the app means it launches
# cleanly even when copied out of the DMG, and notarizing the DMG means the
# disk image opens without a Gatekeeper prompt.
#
# Usage:
#   scripts/package-ivrix-dmg.sh                       # uses /tmp/ivrix-stage/Ivrix.app
#   APP=/path/to/Ivrix.app scripts/package-ivrix-dmg.sh
#   NOTARY_PROFILE=ivrix SIGN_IDENTITY="Developer ID Application: ..." scripts/package-ivrix-dmg.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO/scripts/ivrix.entitlements"
HELPER_ENTITLEMENTS="$REPO/cmux-helper.entitlements"
APP="${APP:-/tmp/ivrix-stage/Ivrix.app}"
WORK="${TMPDIR:-/tmp}/ivrix-dmg"
DESKTOP="$HOME/Desktop"
DMG="$DESKTOP/Ivrix.dmg"
VOLNAME="Ivrix"

test -d "$APP" || { echo "ERROR: $APP missing — run scripts/build-ivrix.sh first" >&2; exit 1; }
test -f "$ENTITLEMENTS" || { echo "ERROR: $ENTITLEMENTS missing" >&2; exit 1; }
test -f "$HELPER_ENTITLEMENTS" || { echo "ERROR: $HELPER_ENTITLEMENTS missing" >&2; exit 1; }

# --- identity ---
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o 'Developer ID Application: [^"]*' | head -1)"
fi
test -n "$SIGN_IDENTITY" || { echo "ERROR: no 'Developer ID Application' identity. Set SIGN_IDENTITY=..." >&2; exit 1; }
echo "==> signing identity: $SIGN_IDENTITY"

# --- notary profile ---
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  for p in ivrix cmux notary AC_PASSWORD; do
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then NOTARY_PROFILE="$p"; break; fi
  done
fi
test -n "$NOTARY_PROFILE" || { echo "ERROR: no working notarytool keychain profile. Set NOTARY_PROFILE=..." >&2; exit 1; }
echo "==> notary profile: $NOTARY_PROFILE"

rm -rf "$WORK"; mkdir -p "$WORK"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Ivrix.app"
APP="$STAGE/Ivrix.app"

# --- 1. re-sign Developer ID + hardened runtime (inside-out) ---
# A single `codesign --deep` does NOT sign nested executables under
# Contents/Resources/bin, so notarization rejects them as unsigned.
echo "==> [1/6] re-signing (Developer ID + hardened runtime, inside-out)"
COMMON=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")

for helper in "$APP/Contents/Resources/bin"/*; do
  [[ -f "$helper" ]] || continue
  echo "    helper: $(basename "$helper")"
  codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
done

if [[ -d "$APP/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    echo "    plugin: $(basename "$plugin")"
    codesign "${COMMON[@]}" --deep "$plugin"
  done < <(find "$APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi

if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    echo "    framework: $(basename "$framework")"
    codesign "${COMMON[@]}" --deep "$framework"
  done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi

echo "    main bundle: Ivrix.app"
codesign "${COMMON[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# --- 2. notarize the app ---
echo "==> [2/6] notarizing app (this can take minutes)"
ditto -c -k --keepParent "$APP" "$WORK/Ivrix-app.zip"
xcrun notarytool submit "$WORK/Ivrix-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> [3/6] stapling app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# --- 4. build the DMG ---
echo "==> [4/6] building DMG"
SRCDIR="$WORK/dmgsrc"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
cp -R "$APP" "$SRCDIR/Ivrix.app"
ln -s /Applications "$SRCDIR/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$SRCDIR" -ov -format UDZO -quiet "$DMG"

echo "==> [5/6] signing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# --- 6. notarize + staple the DMG ---
echo "==> [6/6] notarizing DMG (this can take minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "==> verification"
spctl -a -vvv --type exec "$APP" 2>&1 | tail -3 || true
spctl -a -vvv --type open --context context:primary-signature "$DMG" 2>&1 | tail -3 || true
ls -lh "$DMG"
echo "DONE: $DMG (notarized + stapled; app inside is stapled too)"
