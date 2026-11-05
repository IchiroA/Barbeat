#!/bin/bash
# Builds "Barbeat Sandbox Test.app": the normal app, but running in the App Sandbox (as the Mac App
# Store requires), with its own bundle ID so it can't disturb the installed Barbeat's settings or permission.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh >/dev/null
ID="com.ia.MenuBarEQ.sandboxtest"
APP="build/sandbox-test/Barbeat Sandbox Test.app"
rm -rf build/sandbox-test && mkdir -p build/sandbox-test
ditto build/Barbeat.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Barbeat Sandbox Test" \
    -c "Set :CFBundleDisplayName Barbeat Sandbox Test" "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
codesign --force --options runtime --entitlements Resources/Sandbox.entitlements --sign "${IDENTITY:--}" "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "app-sandbox|audio-input"
echo "Built: $APP (container: ~/Library/Containers/$ID)"
