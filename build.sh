#!/bin/bash
# Builds DoneBoard.app. Command Line Tools are enough - no Xcode required.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DoneBoard.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Sounds"
find Resources/Sounds -type f ! -name "*.md" -exec cp {} "$APP/Contents/Resources/Sounds" \; 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Compiling ($ARCH)…"
swiftc -O -swift-version 5 \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos14.0" \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/DoneBoard" \
  Sources/Shared/*.swift Sources/Mac/*.swift

Tools/stamp-commit.sh "$APP/Contents/Info.plist"

echo "Signing (ad-hoc)…"
codesign --force --sign - --identifier com.example.doneboard "$APP"

echo "Built $(cd build && pwd)/DoneBoard.app"
