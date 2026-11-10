#!/bin/bash
# Rebuilds every app icon - the Mac's .icns and the iPhone's - from the generated art.
#
# The source art is full-bleed - the rounded square touches all four edges - but a
# macOS icon is expected to leave a margin so it sits the same size as its neighbours
# in the Dock. Apple's grid puts an 824pt body on a 1024pt canvas; measuring shipped
# apps agrees (Claude.app 82%, Comet 80.7%). BODY is that fraction.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Calendar Task App Logos/icon-accent-knockout.png}"
BODY="${2:-0.805}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -swift-version 5 -sdk "$SDK" -target "${ARCH}-apple-macos14.0" \
  -framework AppKit -parse-as-library -o "$WORK/iconkit" Tools/iconkit.swift

"$WORK/iconkit" make "$SOURCE" "$WORK/AppIcon.iconset" "$BODY"
iconutil --convert icns "$WORK/AppIcon.iconset" --output Resources/AppIcon.icns

# The phone gets the same art full-bleed and opaque. The loose sizes feed build-ios.sh,
# which copies files into the simulator bundle rather than compiling a catalog; the
# asset catalog's single 1024 is what the Xcode device build compiles, and Xcode
# generates every smaller size from it.
"$WORK/iconkit" ios "$SOURCE" Resources/iOSIcons
cp Resources/iOSIcons/AppIcon1024.png Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png

echo "Built Resources/AppIcon.icns, Resources/iOSIcons and the asset catalog from $SOURCE"
