#!/usr/bin/env bash
# Removes Sparkle's XPC services from the built app. They exist for sandboxed
# hosts, and Sissy is not sandboxed, so nothing ever launches them; left in,
# they are two more nested binaries for signing and notarization to answer for.
# Adapted from Sparkle's own "Removing XPC Services" script, which runs only on
# install builds: that is what `xcodebuild archive` is, and an archive is what
# a release exports.

set -euo pipefail

[[ "${ACTION:-}" == "install" ]] || exit 0

FRAMEWORK="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Frameworks/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { echo "error: $FRAMEWORK not found" >&2; exit 1; }

rm -rf "$FRAMEWORK/Versions/Current/XPCServices" "$FRAMEWORK/XPCServices"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata "$FRAMEWORK"
