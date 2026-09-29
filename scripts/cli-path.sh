#!/usr/bin/env bash
# Prints the path of the sissy-cli binary a configuration builds to.
#
# Usage: scripts/cli-path.sh Debug|Release
#
# `-showBuildSettings` resolves the path without building, so it names
# whatever the last successful build of that configuration left there: build
# the scheme first.

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 Debug|Release" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
products="$(
  xcodebuild -project "$REPO_ROOT/app/Sissy.xcodeproj" -scheme sissy-cli \
    -configuration "$1" -showBuildSettings 2>/dev/null \
    | awk -F= '/BUILT_PRODUCTS_DIR/ && !found {print $2; found = 1}' | xargs
)"
[[ -n "$products" ]] || { echo "no BUILT_PRODUCTS_DIR for sissy-cli $1" >&2; exit 1; }
printf '%s/sissy-cli\n' "$products"
