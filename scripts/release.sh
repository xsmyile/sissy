#!/usr/bin/env bash
# Build, sign, notarize, staple Sissy.app and package as DMG.
# Usage: scripts/release.sh [version]
#   version defaults to the latest git tag (scripts/version.sh); the build
#   number is always the commit count and is not overridable
#
# Prerequisites (one-time):
#   - "Developer ID Application: ... (AS75YRKL95)" cert in login keychain
#   - notarytool credentials stored:
#       xcrun notarytool store-credentials "sissy-notary" \
#         --apple-id "<email>" --team-id "AS75YRKL95" --password "<app-specific-pw>"
#   - brew install create-dmg xcodegen (xcbeautify optional)
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
      sed -n '2,13p' "$0"; exit 0 ;;
  esac
done

VERSION="$("$REPO_ROOT/scripts/version.sh" marketing)"
BUILD="$("$REPO_ROOT/scripts/version.sh" build)"
if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
  VERSION="$1"
fi
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
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

log "version: $VERSION (build $BUILD)"
mkdir -p "$DIST_DIR"
BUILD_DIR="$APP_DIR/build"
rm -rf "$BUILD_DIR"

# Generate project + build Release
log "xcodegen generate"
( cd "$APP_DIR" && xcodegen generate )

log "xcodebuild archive"
# Force Manual signing with the Developer ID identity. Automatic style
# can fall back to a Mac Development cert when both exist in the
# keychain — the resulting bundle won't notarize and the failure only
# surfaces after `notarytool submit` (minutes later). Manual + explicit
# identity fails fast at build time if the cert is missing.
ARCHIVE_PATH="$BUILD_DIR/Sissy.xcarchive"
archive() {
  xcodebuild \
    -project "$APP_DIR/Sissy.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    archive
}
if command -v xcbeautify >/dev/null; then
  archive | xcbeautify
else
  archive
fi

# Archive and export is the path Apple and Sparkle both document for a
# Developer ID app: the export signs every nested binary with the identity, a
# secure timestamp and no get-task-allow, Sparkle's helpers included.
log "xcodebuild -exportArchive"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$APP_DIR/ExportOptions.plist"

APP_PATH="$BUILD_DIR/export/Sissy.app"
[[ -d "$APP_PATH" ]] || die "export did not produce $APP_PATH"

# The plists carry only $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION), so a
# literal reintroduced into either one would silently ship a bundle whose About
# window disagrees with the DMG, the cask and the tag.
log "verify bundle version"
for pair in "CFBundleShortVersionString:$VERSION" "CFBundleVersion:$BUILD"; do
  key="${pair%%:*}"
  want="${pair#*:}"
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_PATH/Contents/Info.plist")"
  [[ "$got" == "$want" ]] || die "$key is '$got', expected '$want'"
done

# Notarization preflight, on the app and on every binary nested in it: the
# Developer ID authority (a Mac Development cert also carries the team id but
# cannot be notarized), a secure timestamp, the hardened runtime, and no
# get-task-allow.
log "verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
for code in "$APP_PATH" "$SPARKLE" "$SPARKLE/Versions/Current/Autoupdate" "$SPARKLE/Versions/Current/Updater.app"; do
  info="$(codesign -dvv "$code" 2>&1)"
  grep -q "Authority=$SIGN_IDENTITY" <<<"$info" || die "$code not signed with '$SIGN_IDENTITY' authority"
  grep -q "Timestamp=" <<<"$info" || die "no secure timestamp on $code"
  grep -q "flags=.*(runtime)" <<<"$info" || die "no hardened runtime on $code"
  if codesign -d --entitlements - "$code" 2>/dev/null | grep -q "get-task-allow"; then
    die "get-task-allow present on $code"
  fi
done
[[ ! -e "$SPARKLE/Versions/Current/XPCServices" ]] || die "Sparkle XPC services still bundled"

# The cask copies Sissy.app out of the DMG, so a ticket stapled to the DMG
# alone never reaches /Applications and the first launch has to look it up
# online. Notarize and staple the app itself before the DMG is built from it.
log "notarize app"
NOTARY_DIR="$(mktemp -d -t sissy-notary)"
NOTARY_ZIP="$NOTARY_DIR/Sissy.zip"
trap 'rm -rf "$NOTARY_DIR"' EXIT
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

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

# Notarize the DMG too, so a download opened straight from Releases verifies
# offline as well; the app inside already carries its own ticket.
log "notarize DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" \
  || echo "warning: spctl DMG assess returned non-zero (often OK for DMGs)"

# Checksum
( cd "$DIST_DIR" && shasum -a 256 "Sissy-$VERSION.dmg" > "Sissy-$VERSION.dmg.sha256" )

log "artifacts:"
ls -lh "$DIST_DIR/Sissy-$VERSION".{dmg,dmg.sha256}

if [[ "$PUBLISH" == 1 ]]; then
  command -v gh >/dev/null || die "gh CLI required for --publish"
  TAG="v$VERSION"
  # Without --verify-tag, `gh release create` creates a missing tag itself,
  # from the remote default branch: the DMG built here would publish under a
  # tag naming a different commit. The notes are the tag's own annotation,
  # the same source release.yml reads, so the two paths cannot disagree about
  # what a release says. A lightweight tag resolves `%(contents)` to its
  # commit message, which is why the object type is checked rather than the
  # text alone.
  [[ "$(git -C "$REPO_ROOT" cat-file -t "$TAG" 2>/dev/null)" == "tag" ]] \
    || die "$TAG is not an annotated tag; write one with: git tag -a -f $TAG"
  NOTES="$(git -C "$REPO_ROOT" tag -l --format='%(contents)' "$TAG")"
  [[ -n "${NOTES//[[:space:]]/}" && "${NOTES//[[:space:]]/}" != "$TAG" ]] \
    || die "$TAG carries no annotation beyond its own name; the release notes are read from it"
  log "gh release create $TAG"
  gh release create "$TAG" \
    "$DMG_PATH" "$DMG_PATH.sha256" \
    --title "Sissy $VERSION" \
    --verify-tag \
    --notes "$NOTES"
fi

log "done. Test with: open $DMG_PATH"
