#!/usr/bin/env bash
# Runs the SwiftLint release the baseline was generated with, whatever is on
# PATH. `--strict` fails on anything `.swiftlint-baseline` does not record, so
# a newer SwiftLint that words a rule differently or adds a violation would
# fail every build at once, a tag push included; CI and the pre-commit hook
# therefore both lint through this script.
#
# Usage: scripts/swiftlint.sh <swiftlint arguments>
#
# The portable build is downloaded once per version into the user's cache and
# checked against its published sha256. Moving to a new release means changing
# both values below and regenerating the baseline in the same commit.

set -euo pipefail

VERSION="0.65.1"
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/sissy/swiftlint/$VERSION"
BINARY="$CACHE/swiftlint"

if [[ ! -x "$BINARY" ]]; then
  mkdir -p "$CACHE"
  staging="$(mktemp -d "$CACHE/download.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
  curl -fsSL -o "$staging/portable_swiftlint.zip" \
    "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip"
  echo "$SHA256  $staging/portable_swiftlint.zip" | shasum -a 256 --check --status \
    || { echo "SwiftLint $VERSION download does not match its sha256" >&2; exit 1; }
  unzip -q "$staging/portable_swiftlint.zip" swiftlint -d "$staging"
  mv -f "$staging/swiftlint" "$BINARY"
  rm -rf "$staging"
  trap - EXIT
fi

exec "$BINARY" "$@"
