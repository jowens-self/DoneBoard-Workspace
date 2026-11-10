#!/bin/bash
# Proves the data layer: merging, the file format, editing, and two devices sharing one file.
#
# There's no test target. The app's own model sources are compiled straight in with the checks
# in Tests/, which needs nothing but Command Line Tools and takes a few seconds. Everything runs
# on files in a temporary folder, and DONEBOARD_DATA points this device's copy and the
# diagnostics log there too, so the real board is never touched. Run it after any change to
# Model.swift or Store.swift, and before committing one.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d -t doneboard-tests)"
# One check makes a file unreadable on purpose; give it back before deleting.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"

# Optimised, as the app ships - one check times a save on a board a few years old.
swiftc -O -swift-version 5 -sdk "$SDK" -target "${ARCH}-apple-macos14.0" \
  -o "$WORK/checks" \
  Sources/Shared/Model.swift Sources/Shared/Store.swift \
  Sources/Shared/SoundFile.swift Sources/Shared/Diagnostics.swift \
  Tests/*.swift 2> "$WORK/compile.txt" || { grep -E "error:" "$WORK/compile.txt" | sort -u; exit 1; }

# A zone with daylight saving, so the checks that cross a clock change mean something.
TZ=America/Chicago \
DONEBOARD_DATA="$WORK/device/doneboard.json" \
DONEBOARD_TEST_DIR="$WORK" \
  "$WORK/checks"
