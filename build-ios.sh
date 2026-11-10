#!/bin/bash
# Builds DoneBoard.app for the iOS Simulator and runs it.
#
# Like build.sh, this is plain swiftc into a hand-made bundle, which works because the
# simulator does not require a provisioning profile. A physical iPhone does - that build
# goes through DoneBoard.xcodeproj instead - generate it with `xcodegen generate` from
# project.yml; see XCODE.md - and needs an Apple ID signed into Xcode.
set -euo pipefail
cd "$(dirname "$0")"

APP="build-ios/DoneBoard.app"
SDK="$(xcrun --show-sdk-path --sdk iphonesimulator)"
ARCH="$(uname -m)"
DEVICE="${DEVICE:-DoneBoard-iPhone}"

rm -rf "$APP"
mkdir -p "$APP"
cp Resources/Info-iOS.plist "$APP/Info.plist"
cp Resources/iOSIcons/*.png "$APP/"
mkdir -p "$APP/Sounds"
find Resources/Sounds -type f ! -name "*.md" -exec cp {} "$APP/Sounds" \; 2>/dev/null || true

echo "Compiling for the simulator ($ARCH)…"
swiftc -O -swift-version 5 \
  -sdk "$SDK" \
  -target "${ARCH}-apple-ios17.0-simulator" \
  -framework SwiftUI -framework UIKit \
  -o "$APP/DoneBoard" \
  Sources/Shared/*.swift Sources/iOS/*.swift

Tools/stamp-commit.sh "$APP/Info.plist"

echo "Signing (ad-hoc)…"
codesign --force --sign - --identifier com.example.doneboard "$APP"

# Reuse a named device so the app's data survives between runs.
if ! xcrun simctl list devices | grep -q "$DEVICE"; then
  RUNTIME="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' | tail -1)"
  echo "Creating simulator $DEVICE on $RUNTIME…"
  xcrun simctl create "$DEVICE" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" "$RUNTIME" >/dev/null
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.example.doneboard

echo "Running on $DEVICE"
