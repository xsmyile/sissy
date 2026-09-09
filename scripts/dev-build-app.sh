#!/usr/bin/env bash
# Build a local Sissy.app that is suitable for testing Server start/stop.
# `SMAppService` rejects CODE_SIGNING_ALLOWED=NO products because the bundled
# LaunchAgent and daemon must live inside a normally signed app bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
TEAM_ID="${DEVELOPMENT_TEAM:-AS75YRKL95}"
CONFIGURATION="${CONFIGURATION:-Debug}"
# Fixed, worktree-independent build location. Two properties matter:
# it is shared by every worktree, so exactly one dev bundle can exist no
# matter which branch you build; and it lives under a dot-directory, which
# Spotlight does not index, so the dev bundle never shows up next to the
# release app in a launcher search.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/.cache/sissy/build-dev}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v xcodegen >/dev/null || die "xcodegen not found. Install it with: brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and select it with xcode-select."
command -v codesign >/dev/null || die "codesign not found."

# Sweep bundles left by the legacy per-worktree path and by a plain
# `xcodebuild` run that forgot `-derivedDataPath`. Without this, every
# worktree and every stray build adds another indexed "Sissy" launcher.
sweep_stray_bundles() {
  local wt
  while read -r wt; do
    [[ -n "$wt" ]] || continue
    [[ "$wt/app/build-dev" == "$DERIVED_DATA_PATH" ]] && continue
    if [[ -d "$wt/app/build-dev" ]]; then
      printf '==> removing stray dev build: %s\n' "$wt/app/build-dev"
      rm -rf "$wt/app/build-dev"
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain | awk '/^worktree /{print $2}')

  local stray
  while read -r stray; do
    [[ -n "$stray" ]] || continue
    printf '==> removing stray dev build: %s\n' "$stray"
    rm -rf "$stray"
  done < <(
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 \
      -path '*/Sissy-*/Build/Products/*/Sissy.app' -type d 2>/dev/null
  )

  # A dev instance launched from a path we just deleted keeps running and
  # keeps owning a status item, so the menubar shows two Sissys. The pattern
  # cannot match /Applications/Sissy.app, so the release app is never hit.
  if pkill -f 'build-dev/Build/Products/[^/]*/Sissy\.app/Contents/MacOS/Sissy' 2>/dev/null; then
    printf '==> stopped a dev instance from a removed build\n'
    sleep 1
  fi
}

sweep_stray_bundles

MARKETING_VERSION="$("$REPO_ROOT/scripts/version.sh" marketing)"
CURRENT_PROJECT_VERSION="$("$REPO_ROOT/scripts/version.sh" build)"

printf '==> xcodegen generate\n'
(cd "$APP_DIR" && xcodegen generate)

printf '==> xcodebuild %s signed build (%s build %s)\n' \
  "$CONFIGURATION" "$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION"
xcodebuild \
  -project "$APP_DIR/Sissy.xcodeproj" \
  -scheme Sissy \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_ALLOWED=YES \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
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

if [[ "${RELAUNCH:-1}" == "1" ]]; then
  # The running instance owns the status item, so a relaunch is the only way
  # to see the new build. Matching on the bundle path leaves the release app
  # in /Applications untouched.
  if pkill -f "$APP_PATH/Contents/MacOS/Sissy" 2>/dev/null; then
    printf '==> stopped the previous dev instance\n'
    sleep 1
  fi
  open "$APP_PATH"
  printf '==> relaunched %s\n' "$APP_PATH"
else
  printf 'Open it with: open "%s"\n' "$APP_PATH"
fi
