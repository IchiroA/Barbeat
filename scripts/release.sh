#!/bin/bash
# Builds a zip of "Barbeat.app" (plus install notes) that you can send to people.
#
# For a zip that opens with no warnings, do this once:
#   1. Create a "Developer ID Application" certificate:
#        Xcode › Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application
#   2. Save notarization credentials in your keychain (asks for an app-specific password
#      from account.apple.com › Sign-In and Security › App-Specific Passwords):
#        xcrun notarytool store-credentials MenuBarEQ --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# Without the certificate it still makes a zip, but friends must approve the app once in System Settings.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-MenuBarEQ}"
APP="build/Barbeat.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE="build/share/Barbeat"
ZIP="build/Barbeat-$VERSION.zip"

./scripts/build.sh

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/MenuBarEQ.entitlements --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "No Developer ID Application certificate found: making an ad-hoc signed zip."
fi

make_zip() {
    rm -rf build/share "$ZIP"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Barbeat.app"
    cp Resources/HowToInstall.txt "$STAGE/How to install.txt"
    ditto -c -k --keepParent "$STAGE" "$ZIP"
}
make_zip

NOTARIZED=no
if [ -n "$IDENTITY" ]; then
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "Sending to Apple for notarization (usually a few minutes)..."
        xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$APP"
        make_zip   # re-zip so the stapled ticket travels with the app
        spctl --assess --type execute --verbose=2 "$APP"
        NOTARIZED=yes
    else
        echo "No notarization credentials named '$PROFILE' in your keychain: skipping notarization."
    fi
fi

echo
echo "Ready to share: $ZIP (signed: ${IDENTITY:-ad-hoc}, notarized: $NOTARIZED)"
