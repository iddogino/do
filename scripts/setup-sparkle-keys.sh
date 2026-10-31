#!/usr/bin/env bash
# One-time setup of Sparkle's EdDSA update-signing keys.
#
#   scripts/setup-sparkle-keys.sh [owner/repo]
#
# - Reuses the key pair in the git-ignored .env if present; otherwise generates a new Ed25519
#   pair with CryptoKit (no keychain involved) and saves it there (mode 600).
# - Proves the private key works with Sparkle's own `sign_update` (as CI uses it) and that its
#   signatures verify under the public key.
# - Stores the private key as the SPARKLE_PRIVATE_KEY repository secret and the public key as the
#   SPARKLE_PUBLIC_KEY repository variable.
# The private key is never printed. Back up .env: losing the key means installed copies can't
# verify future updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ENV_FILE="$ROOT/.env"
SPARKLE_VERSION="2.10.1"

# Refuse to write secrets to a file git would pick up.
git -C "$ROOT" check-ignore -q "$ENV_FILE" || { echo "error: $ENV_FILE is not git-ignored" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

PUBLIC_KEY="$(sed -n 's/^SPARKLE_PUBLIC_KEY=//p' "$ENV_FILE" | tail -1)"
PRIVATE_KEY="$(sed -n 's/^SPARKLE_PRIVATE_KEY=//p' "$ENV_FILE" | tail -1)"
if [[ -n "$PUBLIC_KEY" && -n "$PRIVATE_KEY" ]]; then
  echo "Reusing the Sparkle key pair from $ENV_FILE"
else
  swift "$ROOT/scripts/sparkle-keygen.swift" generate "$WORK/keys"
  PUBLIC_KEY="$(sed -n 1p "$WORK/keys")"
  PRIVATE_KEY="$(sed -n 2p "$WORK/keys")"
  grep -v -E '^(SPARKLE_PRIVATE_KEY|SPARKLE_PUBLIC_KEY)=' "$ENV_FILE" > "$WORK/env" || true
  {
    cat "$WORK/env"
    echo "# Sparkle EdDSA update-signing keys ($(date -u +%Y-%m-%d)). Keep a backup; never commit."
    echo "SPARKLE_PUBLIC_KEY=$PUBLIC_KEY"
    echo "SPARKLE_PRIVATE_KEY=$PRIVATE_KEY"
  } > "$ENV_FILE"
  echo "Generated a new Sparkle key pair and saved it to $ENV_FILE"
fi
printf '%s' "$PRIVATE_KEY" > "$WORK/private.key"

# Round-trip through Sparkle's sign_update exactly as the release workflow does.
curl -sSfL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" |
  tar -xJ -C "$WORK"
head -c 4096 /dev/urandom > "$WORK/probe.bin"
ATTRS="$("$WORK/bin/sign_update" --ed-key-file "$WORK/private.key" "$WORK/probe.bin")"
SIGNATURE="$(echo "$ATTRS" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[[ -n "$SIGNATURE" ]] || { echo "error: sign_update rejected the key: $ATTRS" >&2; exit 1; }
swift "$ROOT/scripts/sparkle-keygen.swift" verify "$PUBLIC_KEY" "$WORK/probe.bin" "$SIGNATURE" ||
  { echo "error: signature does not verify under the public key" >&2; exit 1; }
echo "Verified: sign_update signatures validate under the public key."

gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$WORK/private.key"
gh variable set SPARKLE_PUBLIC_KEY --repo "$REPO" --body "$PUBLIC_KEY"
echo "Set SPARKLE_PRIVATE_KEY (secret) and SPARKLE_PUBLIC_KEY (variable) on $REPO."
echo "Public key: $PUBLIC_KEY"
