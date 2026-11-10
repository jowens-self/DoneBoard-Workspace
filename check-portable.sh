#!/bin/bash
# Type-checks Sources/Shared against the Mac's and the phone's SDKs, and rejects path calls that
# quietly touch the disk.
#
# The Mac build staying green says nothing about whether the shared layer still
# compiles for iOS - an AppKit import in Store.swift would go unnoticed for weeks.
# This catches it the day it happens, in about two seconds.
set -euo pipefail
cd "$(dirname "$0")"
ARCH="$(uname -m)"
STATUS=0

for PLATFORM in macos ios; do
  case "$PLATFORM" in
    macos) SDK="$(xcrun --show-sdk-path --sdk macosx)"
           TARGET="${ARCH}-apple-macos14.0"
           EXTRA=(Sources/Mac/Platform.swift) ;;
    ios)   SDK="$(xcrun --show-sdk-path --sdk iphonesimulator)"
           TARGET="${ARCH}-apple-ios17.0-simulator"
           EXTRA=(Sources/iOS/Platform.swift) ;;
  esac
  FILES=(Sources/Shared/*.swift "${EXTRA[@]}")
  printf "%-7s " "$PLATFORM"
  if swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -typecheck \
       "${FILES[@]}" 2>/tmp/portable-$PLATFORM.txt; then
    echo "shared layer OK"
  else
    echo "SHARED LAYER BROKEN"
    grep -E "error:" "/tmp/portable-$PLATFORM.txt" | sed 's/^/         /' | sort -u | head -8
    STATUS=1
  fi
done
# Appending a path component without saying whether it is a folder makes Foundation ask the file
# system - a network round trip when the path is on a share. That froze the phone for 16 seconds on
# the main thread (SyncLocation.fileURL, 2026-09-15), so the one-argument form isn't allowed.
# Standardizing a path asks it too, with a stat: Store.relocate froze the phone on that twice in
# October. Store.samePlace compares two URLs from their text instead.
printf "%-7s " "paths"
# Comments may name them; code may not. A search that finds nothing is the good outcome, hence || true.
{
  grep -nE 'appendingPathComponent\(' Sources/Shared/*.swift Sources/Mac/*.swift Sources/iOS/*.swift \
    | grep -v 'isDirectory:' || true
  grep -nE 'standardizedFileURL|standardizingPath|resolvingSymlinksInPath' \
    Sources/Shared/*.swift Sources/Mac/*.swift Sources/iOS/*.swift \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
} > /tmp/portable-paths.txt
if [ -s /tmp/portable-paths.txt ]; then
  echo "A PATH CALL THAT ASKS THE DISK - see check-portable.sh"
  sed 's/^/         /' /tmp/portable-paths.txt | head -8
  STATUS=1
else
  echo "no path call asks the disk"
fi
exit $STATUS
