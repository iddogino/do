#!/usr/bin/env bash
# Re-signs Do.app for Developer ID distribution, inside-out, with the hardened runtime and a
# secure timestamp: Sparkle's nested helpers first, then the framework, then the app with its
# entitlements. (Sparkle's documented recipe for apps not exported through Xcode Organizer.)
#
#   scripts/ci/sign-app.sh <path/to/Do.app> "<Developer ID Application: … (TEAMID)>" <entitlements>
set -euo pipefail

APP="${1:?app path}"
IDENTITY="${2:?signing identity}"
ENTITLEMENTS="${3:?entitlements plist}"

sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  V="$SPARKLE/Versions/B"
  [[ -d "$V/XPCServices/Installer.xpc" ]] && sign "$V/XPCServices/Installer.xpc"
  [[ -d "$V/XPCServices/Downloader.xpc" ]] && sign --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  [[ -e "$V/Autoupdate" ]] && sign "$V/Autoupdate"
  [[ -d "$V/Updater.app" ]] && sign "$V/Updater.app"
  sign "$SPARKLE"
fi

# Any other embedded frameworks / dylibs.
find "$APP/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) ! -name "Sparkle.framework" -print0 2>/dev/null |
  while IFS= read -r -d '' item; do sign "$item"; done

sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime|Timestamp" || true
