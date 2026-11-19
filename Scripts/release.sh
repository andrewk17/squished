#!/usr/bin/env bash
# Builds a notarized, stapled build/Squished.zip ready to attach to a
# GitHub release. It does not publish anything.
#
# Needs a Developer ID Application identity in the keychain and an App Store
# Connect API key for notarytool:
#   ASC_KEY_ID=… ASC_ISSUER_ID=… [ASC_KEY_PATH=…/AuthKey_<id>.p8] Scripts/release.sh
# ASC_KEY_PATH defaults to ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}

"$ROOT/Scripts/package-app.sh" --release
APP="$ROOT/build/Squished.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
# A fixed name keeps https://github.com/andrewk17/squished/releases/latest/download/Squished.zip stable.
ZIP="$ROOT/build/Squished.zip"

# Submit a zip, staple the ticket to the app, then zip the stapled app again
# so the download opens without a network check.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --wait --timeout 30m \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
lipo -archs "$APP/Contents/MacOS/Squished"
shasum -a 256 "$ZIP"
printf 'Ready: %s (version %s)\n' "$ZIP" "$VERSION"
