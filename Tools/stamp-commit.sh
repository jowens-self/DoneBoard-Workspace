#!/bin/bash
# Writes the commit being built into an app's Info.plist as DBGitCommit, so the diagnostics log
# can say exactly which code a device is running. A trailing + means the build also carried
# changes that weren't committed yet.
#
#   Tools/stamp-commit.sh path/to/DoneBoard.app/Info.plist
#
# build.sh and build-ios.sh call it before signing; the Xcode targets run it as a post-build
# script, which Xcode also runs before signing.
set -euo pipefail
PLIST="$1"
cd "$(dirname "$0")/.."

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- Sources Resources project.yml 2>/dev/null)" ]; then
  COMMIT="$COMMIT+"
fi

/usr/libexec/PlistBuddy -c "Delete :DBGitCommit" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :DBGitCommit string $COMMIT" "$PLIST"
echo "Stamped commit $COMMIT"
