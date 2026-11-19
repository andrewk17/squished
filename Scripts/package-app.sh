#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
    echo 'Squished.app must be built and signed on macOS.' >&2
    exit 1
fi
# --release: a universal (Apple silicon + Intel) build signed for notarization
# (Developer ID, hardened runtime, secure timestamp). Scripts/release.sh uses it.
RELEASE=0
[[ ${1:-} == --release ]] && RELEASE=1
BUILD_ARGS=(--package-path "$ROOT" -c release)
((RELEASE)) && BUILD_ARGS+=(--arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" --product Squished
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
APP="$ROOT/build/Squished.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Squished" "$APP/Contents/MacOS/Squished"
chmod 755 "$APP/Contents/MacOS/Squished"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.andrewkim.squished</string>
<key>CFBundleName</key><string>Squished</string>
<key>CFBundleDisplayName</key><string>Squished</string>
<key>CFBundleExecutable</key><string>Squished</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Sign with the local Developer ID when there is one. Without --release the build
# is not notarized (local use only). macOS 27's menu bar may not keep an ad hoc
# build's position; set SIGNING_IDENTITY=- to force ad hoc signing.
if [[ -z ${SIGNING_IDENTITY:-} ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p') || SIGNING_IDENTITY=
    SIGNING_IDENTITY=${SIGNING_IDENTITY%%$'\n'*}
fi
SIGN_ARGS=(--force --sign "${SIGNING_IDENTITY:--}")
if ((RELEASE)); then
    if [[ ${SIGNING_IDENTITY:-} != "Developer ID Application:"* ]]; then
        echo 'A release build needs a Developer ID Application identity.' >&2
        exit 1
    fi
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Packaged %s (signed: %s)\n' "$APP" "${SIGNING_IDENTITY:--}"
# --install: replace /Applications/Squished.app, the copy to launch day to day.
if [[ ${1:-} == --install ]]; then
    ditto "$APP" /Applications/Squished.app.new
    rm -rf /Applications/Squished.app
    mv /Applications/Squished.app.new /Applications/Squished.app
    printf 'Installed /Applications/Squished.app\n'
fi
