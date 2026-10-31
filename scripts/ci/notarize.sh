#!/usr/bin/env bash
# Notarizes and staples a .app, .dmg, or .zip.
#
# Credentials (pick one):
#   App Store Connect API key:  NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID, NOTARY_API_KEY_P8 (base64 .p8)
#   Apple ID:                   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
set -euo pipefail

TARGET="${1:?path to .app, .dmg or .zip}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" && -n "${NOTARY_API_KEY_P8:-}" ]]; then
  echo "$NOTARY_API_KEY_P8" | base64 --decode > "$WORK/AuthKey.p8"
  AUTH=(--key "$WORK/AuthKey.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "error: no notarization credentials" >&2
  exit 1
fi

SUBMIT="$TARGET"
if [[ -d "$TARGET" ]]; then
  # notarytool takes archives, not bundles.
  SUBMIT="$WORK/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

OUTPUT="$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --timeout 45m --output-format json)"
echo "$OUTPUT"
STATUS="$(echo "$OUTPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(echo "$OUTPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  echo "error: notarization status: $STATUS" >&2
  exit 1
fi

if [[ "$TARGET" != *.zip ]]; then
  xcrun stapler staple "$TARGET"
  xcrun stapler validate "$TARGET"
fi
