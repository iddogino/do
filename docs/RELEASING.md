# Releasing Do

## Versioning

SemVer tags drive everything:

| Tag | GitHub release | Sparkle feed |
| --- | --- | --- |
| `v0.1.0-rc.1` | Pre-release | Not served (the feed follows the *latest* non-pre-release) |
| `v0.1.0` | Release, marked latest | Served to all users |

`CFBundleShortVersionString` is the tag without the `v`. `CFBundleVersion` is the Release workflow's run number, which only ever increases, so Sparkle orders builds correctly.

## What the Release workflow does

1. Validates the tag (`vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-rc.N`).
2. Builds `Do.app` (Release) with the version baked in.
3. Signs it with Developer ID (hardened runtime, timestamp), Sparkle's helpers first.
4. Notarizes and staples the app.
5. Builds `Do-<version>.dmg`, signs it, then notarizes and staples it.
6. Signs the DMG for Sparkle (EdDSA) and writes `appcast.xml`.
7. Publishes a GitHub release with the DMG, `appcast.xml`, and `SHA256SUMS.txt`.

Each signing step runs only when its secrets exist. Without any secrets you still get a (clearly labelled) unsigned DMG.

## One-time setup

### Repository secrets (Settings ▸ Secrets and variables ▸ Actions)

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of your **Developer ID Application** certificate + private key exported as .p12: `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The .p12 export password |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID (Users and Access ▸ Integrations ▸ Team Keys, role *Developer*) |
| `NOTARY_API_ISSUER_ID` | The issuer ID shown on the same page |
| `NOTARY_API_KEY_P8` | Base64 of the downloaded `AuthKey_XXXX.p8` |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (set by `scripts/setup-sparkle-keys.sh`) |

Instead of the API key, notarization also accepts `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` (with `APPLE_TEAM_ID`).

Set secrets from a file without pasting them anywhere:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD          # prompts
gh secret set APPLE_TEAM_ID --body ABCDE12345
gh secret set NOTARY_API_KEY_ID --body XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8
```

### Repository variable

| Variable | What it is |
| --- | --- |
| `SPARKLE_PUBLIC_KEY` | Sparkle EdDSA public key, embedded in the app as `SUPublicEDKey` |

`scripts/setup-sparkle-keys.sh` sets both. It keeps the key pair in the git-ignored `.env` at the repo root (mode 600), generating an Ed25519 pair with CryptoKit on first run and reusing `.env` afterwards. Before uploading anything, it checks the key round-trips through Sparkle's own `sign_update`. Back up `.env` (e.g. in a password manager): losing the private key means existing installs can't verify future updates. To sign locally with Sparkle's tools, use `sign_update --ed-key-file <(sed -n 's/^SPARKLE_PRIVATE_KEY=//p' .env) Do.dmg`.

### Updates require a public repository

The app's feed URL is `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` (set by `SPARKLE_FEED_URL` in `Config/Base.xcconfig`). GitHub only serves release assets anonymously for public repositories. For a private repo, host `appcast.xml` and the DMGs elsewhere (e.g. a bucket) and point `SPARKLE_FEED_URL` there.

## Mac App Store

Do is distributed outside the Mac App Store. The App Sandbox forbids posting input events to other apps and running arbitrary shell commands, which are Do's core features. The entitlements file declares this explicitly (`com.apple.security.app-sandbox = false`).
