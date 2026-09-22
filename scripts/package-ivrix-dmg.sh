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

# Ivrix does not ship the cmux Cloud tunnel. Two independent reasons, both from
# upstream's scripts/sign-cmux-bundle.sh:
#   1. The extension's entitlements are hardcoded to cmux's team (7WLXT3NR37)
#      and require a Developer ID NetworkExtension provisioning profile. Ivrix
#      signs as Q2V86449AC and has no such profile, so the extension could never
#      activate.
#   2. macOS rejects com.apple.security.cs.allow-unsigned-executable-memory and
#      com.apple.security.cs.disable-library-validation on an app that bundles a
#      packet-tunnel system extension, and scripts/ivrix.entitlements needs both.
#      Shipping it would break app launch, not just notarization.
# Upstream does exactly this (rm -rf) whenever the profile lacks the capability.
if [[ -d "$APP/Contents/Library/SystemExtensions" ]]; then
  echo "    removing Contents/Library/SystemExtensions (Ivrix has no Cloud tunnel capability)"
  rm -rf "$APP/Contents/Library/SystemExtensions"
fi

for helper in "$APP/Contents/Resources/bin"/*; do
  [[ -f "$helper" ]] || continue
  # Non-Mach-O helpers are sealed by the bundle signature. Signing a script
  # directly stores the signature in an xattr, which Sparkle's BinaryDelta
  # refuses to diff and which would block delta updates.
  if ! /usr/bin/file -b "$helper" | grep -q 'Mach-O'; then
    echo "    (sealed by bundle) $(basename "$helper")"
    continue
  fi
  echo "    helper: $(basename "$helper")"
  codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
done

# Nested Computer Use helper app. Not covered by the bin/PlugIns/Frameworks
# loops, which is why notarization rejected it as unsigned. Signed with the
# helper entitlements and WITHOUT --deep, matching upstream step 2.
if [[ -d "$APP/Contents/Library/cmux Computer Use.app" ]]; then
  echo "    nested app: cmux Computer Use.app"
  codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" \
    "$APP/Contents/Library/cmux Computer Use.app"
fi

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

# --- 1b. pre-flight: every Mach-O must be Developer ID signed + hardened ---
# Apple's notary service takes minutes to tell you about an unsigned nested
# binary. This is the same check locally, in seconds. Submission 949eb880
# (Ivrix 1.2.0) failed on exactly this: two nested bundles under
# Contents/Library that the signing loops above did not reach.
echo "==> [1b/6] pre-flight signature audit"
preflight_failed=0
while IFS= read -r -d '' macho; do
  /usr/bin/file -b "$macho" | grep -q 'Mach-O' || continue
  details="$(codesign -dvv "$macho" 2>&1 || true)"
  rel="${macho#"$APP"/}"
  if ! grep -q "^Authority=$SIGN_IDENTITY\$" <<<"$details"; then
    echo "    NOT Developer ID signed: $rel" >&2
    preflight_failed=1
    continue
  fi
  if ! grep -q 'flags=.*runtime' <<<"$details"; then
    echo "    missing hardened runtime: $rel" >&2
    preflight_failed=1
  fi
done < <(find "$APP" -type f -perm +111 -print0)

if [[ -d "$APP/Contents/Library/SystemExtensions" ]]; then
  echo "    Contents/Library/SystemExtensions still present" >&2
  preflight_failed=1
fi

if [[ "$preflight_failed" -ne 0 ]]; then
  echo "ERROR: pre-flight failed; not submitting to Apple." >&2
  exit 1
fi
echo "    all nested Mach-O binaries: Developer ID + hardened runtime"

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
