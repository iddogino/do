#!/usr/bin/env bash
# Imports the Developer ID Application certificate (base64 .p12 in $MACOS_CERTIFICATE_P12) into
# a temporary keychain and prints the signing identity name.
set -euo pipefail

: "${MACOS_CERTIFICATE_P12:?}" "${MACOS_CERTIFICATE_PASSWORD:?}"
KEYCHAIN="${RUNNER_TEMP:-/tmp}/do-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12="${RUNNER_TEMP:-/tmp}/do-certificate.p12"

echo "$MACOS_CERTIFICATE_P12" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -P "$MACOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Prepend to the search list so codesign finds the identity.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$P12"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity in the certificate" >&2; exit 1; }
echo "$IDENTITY"
