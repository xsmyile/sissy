#!/usr/bin/env bash
# Build a local Sissy.app that is suitable for testing Server start/stop.
# `SMAppService` rejects CODE_SIGNING_ALLOWED=NO products because the bundled
# LaunchAgent and daemon must live inside a normally signed app bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
TEAM_ID="${DEVELOPMENT_TEAM:-AS75YRKL95}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$APP_DIR/build-dev}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v xcodegen >/dev/null || die "xcodegen not found. Install it with: brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and select it with xcode-select."
command -v codesign >/dev/null || die "codesign not found."

printf '==> xcodegen generate\n'
(cd "$APP_DIR" && xcodegen generate)

printf '==> xcodebuild %s signed build\n' "$CONFIGURATION"
xcodebuild \
  -project "$APP_DIR/Sissy.xcodeproj" \
  -scheme Sissy \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_ALLOWED=YES \
  clean build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Sissy.app"
DAEMON_PATH="$APP_PATH/Contents/MacOS/sissy-serverd"

[[ -d "$APP_PATH" ]] || die "build did not produce $APP_PATH"
[[ -x "$DAEMON_PATH" ]] || die "build did not produce bundled daemon at $DAEMON_PATH"

printf '==> inspect code signatures\n'

APP_TEAM="$(
  codesign -dv --verbose=2 "$APP_PATH" 2>&1 \
    | awk -F= '/TeamIdentifier/ { print $2; exit }'
)"
DAEMON_TEAM="$(
  codesign -dv --verbose=2 "$DAEMON_PATH" 2>&1 \
    | awk -F= '/TeamIdentifier/ { print $2; exit }'
)"

[[ -n "$APP_TEAM" ]] || die "Sissy.app has no TeamIdentifier; it is not signed for SMAppService testing"
[[ -n "$DAEMON_TEAM" ]] || die "sissy-serverd has no TeamIdentifier; it is not signed for SMAppService testing"
[[ "$APP_TEAM" == "$DAEMON_TEAM" ]] || die "app team $APP_TEAM does not match daemon team $DAEMON_TEAM"

if ! VERIFY_OUTPUT="$(codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1)"; then
  printf 'warning: strict codesign verification reported:\n%s\n' "$VERIFY_OUTPUT" >&2
fi

printf 'Built signed app: %s\n' "$APP_PATH"
printf 'Open it with: open "%s"\n' "$APP_PATH"
