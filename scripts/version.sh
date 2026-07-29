#!/usr/bin/env bash
# Resolve the version pair that every build path feeds to xcodebuild.
#
#   marketing  release tag with the leading `v` stripped; DEV_VERSION when untagged
#   build      commit count — monotonic, reproducible, independent of CI state
#
# Usage:
#   scripts/version.sh            # MARKETING_VERSION=… / CURRENT_PROJECT_VERSION=… lines
#   scripts/version.sh marketing  # just the marketing version
#   scripts/version.sh build      # just the build number
#
# Override the marketing version with SISSY_VERSION=x.y.z (smoke builds,
# workflow_dispatch). On a tag push GITHUB_REF_NAME supplies it instead.
#
# Requires full history: `git rev-list --count` returns 1 under the default
# actions/checkout fetch-depth, so the release workflow pins fetch-depth: 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_VERSION="0.0.0"

marketing_version() {
  local v="${SISSY_VERSION:-}"
  if [[ -z "$v" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    v="${GITHUB_REF_NAME:-}"
  fi
  if [[ -z "$v" ]]; then
    v="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  fi
  v="${v#v}"
  printf '%s' "${v:-$DEV_VERSION}"
}

build_number() {
  git -C "$REPO_ROOT" rev-list --count HEAD
}

case "${1:-both}" in
  marketing) marketing_version ;;
  build) build_number ;;
  both)
    printf 'MARKETING_VERSION=%s\n' "$(marketing_version)"
    printf 'CURRENT_PROJECT_VERSION=%s\n' "$(build_number)"
    ;;
  *)
    printf 'usage: %s [marketing|build|both]\n' "$0" >&2
    exit 2
    ;;
esac
