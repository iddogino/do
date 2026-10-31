#!/usr/bin/env bash
# Packages an app bundle into a compressed, drag-to-install DMG.
#
#   scripts/make-dmg.sh <path/to/Do.app> <out.dmg> [signing identity]
#
# With a signing identity, the DMG itself is code signed (required for notarization).
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg> [identity]}"
OUT="${2:?usage: make-dmg.sh <app> <out.dmg> [identity]}"
IDENTITY="${3:-}"

[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

VOLNAME="$(basename "$APP" .app)"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs APFS -format ULFO -ov "$OUT" >/dev/null

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
  codesign --verify --verbose=2 "$OUT"
fi
echo "$OUT"
