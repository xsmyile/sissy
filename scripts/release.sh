#!/usr/bin/env bash
# Build, sign, notarize, staple Sissy.app and package as DMG.
# Usage: scripts/release.sh [version]
#   version defaults to MARKETING_VERSION read from app/project.yml
#
# Prerequisites (one-time):
#   - "Developer ID Application: ... (AS75YRKL95)" cert in login keychain
#   - notarytool credentials stored:
#       xcrun notarytool store-credentials "sissy-notary" \
#         --apple-id "<email>" --team-id "AS75YRKL95" --password "<app-specific-pw>"
#   - brew install create-dmg xcodegen
#   - gh CLI authenticated (only if --publish)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"
SCHEME="Sissy"
TEAM_ID="AS75YRKL95"
NOTARY_PROFILE="sissy-notary"
SIGN_IDENTITY="Developer ID Application"

PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

VERSION="${1:-}"
if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
  VERSION="$(awk '/MARKETING_VERSION/ {gsub(/"/, "", $2); print $2; exit}' "$APP_DIR/project.yml")"
fi
if [[ -z "$VERSION" ]]; then
  echo "error: could not determine version" >&2; exit 1
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Prereq checks
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || die "no '$SIGN_IDENTITY' cert in keychain"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing — see header of this script"

log "version: $VERSION"
mkdir -p "$DIST_DIR"
BUILD_DIR="$APP_DIR/build"
rm -rf "$BUILD_DIR"

# Generate project + build Release
log "xcodegen generate"
( cd "$APP_DIR" && xcodegen generate )

log "xcodebuild Release"
# Force Manual signing with the Developer ID identity. Automatic style
# can fall back to a Mac Development cert when both exist in the
# keychain — the resulting bundle won't notarize and the failure only
# surfaces after `notarytool submit` (minutes later). Manual + explicit
# identity fails fast at build time if the cert is missing.
xcodebuild \
  -project "$APP_DIR/Sissy.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  build | xcbeautify 2>/dev/null || \
xcodebuild \
  -project "$APP_DIR/Sissy.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release/Sissy.app"
[[ -d "$APP_PATH" ]] || die "build did not produce $APP_PATH"

# Verify signature. Both --deep verify and authority parse — the
# previous "grep team id" was satisfied even by a Mac Development cert,
# which notarizes but doesn't ship.
log "verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | tee /tmp/sign-app.txt >/dev/null
grep -q "Authority=$SIGN_IDENTITY" /tmp/sign-app.txt \
  || die "app not signed with '$SIGN_IDENTITY' authority"
codesign -dv --verbose=2 "$APP_PATH/Contents/MacOS/sissy-serverd" 2>&1 \
  | tee /tmp/sign-daemon.txt >/dev/null
grep -q "$TEAM_ID" /tmp/sign-daemon.txt \
  || die "sissy-serverd not signed with team $TEAM_ID"

# Notarize app via zip
log "notarize app"
ZIP_PATH="$DIST_DIR/Sissy-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" || die "Gatekeeper rejected app"

# Package DMG
log "create DMG"
DMG_PATH="$DIST_DIR/Sissy-$VERSION.dmg"
rm -f "$DMG_PATH"
create-dmg \
  --volname "Sissy $VERSION" \
  --window-pos 200 120 \
  --window-size 540 320 \
  --icon-size 96 \
  --icon "Sissy.app" 140 160 \
  --hide-extension "Sissy.app" \
  --app-drop-link 400 160 \
  --no-internet-enable \
  "$DMG_PATH" "$APP_PATH"

# Notarize DMG (so Gatekeeper trusts the downloaded file too)
log "notarize DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" \
  || echo "warning: spctl DMG assess returned non-zero (often OK for DMGs)"

# Checksum
( cd "$DIST_DIR" && shasum -a 256 "Sissy-$VERSION.dmg" > "Sissy-$VERSION.dmg.sha256" )

log "artifacts:"
ls -lh "$DIST_DIR/Sissy-$VERSION".{dmg,dmg.sha256,zip}

if [[ "$PUBLISH" == 1 ]]; then
  command -v gh >/dev/null || die "gh CLI required for --publish"
  TAG="v$VERSION"
  log "gh release create $TAG"
  gh release create "$TAG" \
    "$DMG_PATH" "$DMG_PATH.sha256" \
    --title "Sissy $VERSION" \
    --generate-notes
fi

log "done. Test with: open $DMG_PATH"
