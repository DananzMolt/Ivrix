#!/usr/bin/env bash
# Notarize Ivrix on a Mac that has the Apple Developer ID cert + a notarytool
# credential profile. Run this on the Mac Studio.
#
# What it does:
#   1. Downloads the ad-hoc Ivrix.zip from the DananzMolt/cmux release.
#   2. Re-signs the app with your Developer ID Application cert + hardened
#      runtime + the bundled entitlements (notarization requires this; ad-hoc
#      can't be notarized).
#   3. Submits to Apple notarytool and waits.
#   4. Staples the ticket and re-zips a distributable Ivrix-notarized.zip.
#
# Usage:
#   scripts/notarize-ivrix.sh                       # auto-detect identity + profile
#   NOTARY_PROFILE=ivrix scripts/notarize-ivrix.sh  # explicit keychain profile
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/notarize-ivrix.sh
#
# One-time notary profile setup (if you don't have one):
#   xcrun notarytool store-credentials ivrix \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO/scripts/ivrix.entitlements"
WORK="${TMPDIR:-/tmp}/ivrix-notarize"
RELEASE_REPO="DananzMolt/cmux"
RELEASE_TAG="ivrix-latest"

test -f "$ENTITLEMENTS" || { echo "ERROR: $ENTITLEMENTS missing (pull the fork)" >&2; exit 1; }

# --- identity ---
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o 'Developer ID Application: [^"]*' | head -1)"
fi
test -n "$SIGN_IDENTITY" || { echo "ERROR: no 'Developer ID Application' identity found. Set SIGN_IDENTITY=..." >&2; exit 1; }
echo "==> signing identity: $SIGN_IDENTITY"

# --- notary profile ---
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  # Try common names; first that exists wins.
  for p in ivrix cmux notary AC_PASSWORD; do
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then NOTARY_PROFILE="$p"; break; fi
  done
fi
test -n "$NOTARY_PROFILE" || { echo "ERROR: no working notarytool keychain profile. Set NOTARY_PROFILE=... (see store-credentials note in this script)." >&2; exit 1; }
echo "==> notary profile: $NOTARY_PROFILE"

# --- fetch ad-hoc zip from the release ---
rm -rf "$WORK"; mkdir -p "$WORK"
echo "==> downloading Ivrix.zip from $RELEASE_REPO@$RELEASE_TAG"
gh release download "$RELEASE_TAG" --repo "$RELEASE_REPO" --pattern Ivrix.zip --dir "$WORK" --clobber
ditto -x -k "$WORK/Ivrix.zip" "$WORK/unz"
APP="$WORK/unz/Ivrix.app"
test -d "$APP" || { echo "ERROR: Ivrix.app not found after unzip" >&2; exit 1; }

# --- re-sign Developer ID + hardened runtime ---
echo "==> re-signing (Developer ID + hardened runtime)"
codesign --force --deep --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# --- submit + wait ---
SUBMIT_ZIP="$WORK/Ivrix-submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
echo "==> submitting to Apple notary (this can take minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# --- staple + repackage ---
echo "==> stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP" 2>&1 | tail -3 || true

OUT="$HOME/Desktop/Ivrix-notarized.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "DONE: $OUT (notarized + stapled — opens with no Gatekeeper warning)"
