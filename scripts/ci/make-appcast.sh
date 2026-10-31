#!/usr/bin/env bash
# Writes a Sparkle appcast for one release, signing the DMG with the EdDSA private key in
# $SPARKLE_PRIVATE_KEY (as exported by Sparkle's `generate_keys -x`).
#
#   scripts/ci/make-appcast.sh <dmg> <version> <build> <download-url> <release-page-url> <out.xml>
set -euo pipefail

DMG="${1:?}" VERSION="${2:?}" BUILD="${3:?}" URL="${4:?}" PAGE="${5:?}" OUT="${6:?}"
: "${SPARKLE_PRIVATE_KEY:?}" "${SPARKLE_BIN:?path to Sparkle's bin directory}"

KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"

# Prints: sparkle:edSignature="…" length="…"
ATTRS="$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEYFILE" "$DMG")"
[[ "$ATTRS" == *edSignature* ]] || { echo "error: sign_update failed: $ATTRS" >&2; exit 1; }

MIN_OS="${MIN_OS:-26.0}"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Do</title>
    <link>${PAGE}</link>
    <description>Do updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <link>${PAGE}</link>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${PAGE}</sparkle:fullReleaseNotesLink>
      <enclosure url="${URL}" type="application/octet-stream" ${ATTRS} />
    </item>
  </channel>
</rss>
EOF
echo "$OUT"
