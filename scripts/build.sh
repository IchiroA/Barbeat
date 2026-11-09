#!/bin/bash
# Builds "Barbeat.app" into ./build (Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Barbeat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Barbeat "$APP/Contents/MacOS/Barbeat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Pictures for the Settings and Welcome windows (smaller copies of the help site's).
cp Resources/Images/* "$APP/Contents/Resources/"

# Ad-hoc signature with the hardened runtime, so local builds behave like release builds.
# scripts/release.sh re-signs with your Developer ID.
codesign --force --options runtime --entitlements Resources/MenuBarEQ.entitlements --sign - "$APP"
echo "Built: $APP"
