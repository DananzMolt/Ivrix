#!/usr/bin/env bash
# Generate and sign the Sparkle appcast for an Ivrix release.
#
# The "Update Available" button reads this file. It must live on the Ivrix
# repo, not upstream's: an Ivrix build pointed at upstream's appcast is offered
# upstream's releases, and installing one replaces Ivrix with cmux.
#
# The EdDSA private key lives in the login Keychain, put there by Sparkle's
# `generate_keys`. It is never passed on the command line and never written to
# the repo; `sign_update` reads it from the Keychain by account name.
#
# Usage:
#   scripts/ivrix-appcast.sh 1.1.1 ~/Desktop/Ivrix.dmg
#   SPARKLE_ACCOUNT=ivrix scripts/ivrix-appcast.sh 1.1.1 ~/Desktop/Ivrix.dmg
#
# Output: appcast.xml next to the DMG, ready to upload as a release asset.
set -euo pipefail

VERSION="${1:-}"
DMG="${2:-}"
if [[ -z "$VERSION" || -z "$DMG" ]]; then
  echo "usage: $0 <marketing-version> <path-to-dmg>" >&2
  exit 2
fi
test -f "$DMG" || { echo "ERROR: $DMG not found" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="${IVRIX_REPO_SLUG:-DananzMolt/Ivrix}"
TAG="${IVRIX_TAG:-ivrix-v$VERSION}"
OUT="$(dirname "$DMG")/appcast.xml"

# Sparkle ships these tools inside the SPM artifact bundle.
SIGN_UPDATE="${SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE" ]]; then
  SIGN_UPDATE="$(find "${DERIVED:-/tmp/cmux-ivrix-build}/SourcePackages/artifacts" \
    -name sign_update -type f 2>/dev/null | head -1)"
fi
test -x "$SIGN_UPDATE" || {
  echo "ERROR: sign_update not found. Build once, or set SIGN_UPDATE=/path/to/sign_update" >&2
  exit 1
}

# Sparkle needs the build number, which is what it actually compares.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CURRENT_PROJECT_VERSION' /dev/stdin 2>/dev/null <<<"" || true)"
BUILD="${IVRIX_BUILD:-$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$REPO/cmux.xcodeproj/project.pbxproj" | sed 's/.*= \(.*\);/\1/')}"

LENGTH="$(stat -f%z "$DMG")"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$(basename "$DMG")"

echo "==> signing $DMG"
SIG_ARGS=()
[[ -n "${SPARKLE_ACCOUNT:-}" ]] && SIG_ARGS+=(--account "$SPARKLE_ACCOUNT")
# sign_update prints: sparkle:edSignature="..." length="..."
SIGN_OUT="$("$SIGN_UPDATE" "${SIG_ARGS[@]}" "$DMG")"
echo "    $SIGN_OUT"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ivrix</title>
    <link>https://github.com/$REPO_SLUG</link>
    <description>Hebrew-first terminal.</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO_SLUG/releases/tag/$TAG</link>
      <enclosure url="$URL" $SIGN_OUT type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "==> wrote $OUT (version=$VERSION build=$BUILD length=$LENGTH)"
echo "    upload it to the $TAG release so the feed URL resolves:"
echo "    gh release upload $TAG \"$OUT\" --repo $REPO_SLUG"
