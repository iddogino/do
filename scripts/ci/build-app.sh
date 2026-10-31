#!/usr/bin/env bash
# Builds Do.app (Release, ad-hoc signed; release jobs re-sign with Developer ID afterwards)
# and copies it to build/Do.app.
#
#   scripts/ci/build-app.sh <marketing-version> <build-number>
#
# Optional env: SPARKLE_PUBLIC_KEY (enables auto-updates in the built app).
set -euo pipefail

VERSION="${1:?marketing version, e.g. 0.1.0 or 0.1.0-rc.1}"
BUILD="${2:?build number (monotonic integer)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

xcodegen generate --spec project.yml

mkdir -p build
STATUS=0
xcodebuild \
  -project Do.xcodeproj -scheme Do -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build > build/xcodebuild.log 2>&1 || STATUS=$?
grep -E "error:|warning: .*App/Sources|BUILD (SUCCEEDED|FAILED)" build/xcodebuild.log | sort -u || true
if [[ $STATUS -ne 0 ]]; then
  echo "error: xcodebuild exited with $STATUS" >&2
  tail -80 build/xcodebuild.log >&2
  exit "$STATUS"
fi

APP="build/DerivedData/Build/Products/Release/Do.app"
[[ -d "$APP" ]] || { echo "error: build failed, see build/xcodebuild.log" >&2; tail -50 build/xcodebuild.log >&2; exit 1; }
rm -rf build/Do.app
ditto "$APP" build/Do.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" build/Do.app/Contents/Info.plist
