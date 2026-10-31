#!/usr/bin/env bash
# One-time setup of Sparkle's EdDSA update-signing keys.
#
# Generates (or reuses) the key pair in your login keychain with Sparkle's own `generate_keys`,
# then stores the private key as the SPARKLE_PRIVATE_KEY repository secret and the public key as
# the SPARKLE_PUBLIC_KEY repository variable, so release builds can sign updates and embed the
# public key. The private key never touches disk outside a temporary file that is deleted.
#
#   scripts/setup-sparkle-keys.sh [owner/repo]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
VERSION="2.10.1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -sSfL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" | tar -xJ -C "$WORK"

# Prints the existing public key, or creates a new pair (stored in the login keychain).
PUBLIC_KEY="$("$WORK/bin/generate_keys" -p 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" ]]; then
  "$WORK/bin/generate_keys" >/dev/null
  PUBLIC_KEY="$("$WORK/bin/generate_keys" -p)"
fi
"$WORK/bin/generate_keys" -x "$WORK/private.key" >/dev/null

gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$WORK/private.key"
gh variable set SPARKLE_PUBLIC_KEY --repo "$REPO" --body "$PUBLIC_KEY"
echo "Sparkle public key: $PUBLIC_KEY"
echo "Stored SPARKLE_PRIVATE_KEY (secret) and SPARKLE_PUBLIC_KEY (variable) on $REPO."
echo "Back up the private key: it lives in your login keychain as 'Private key for signing Sparkle updates'."
